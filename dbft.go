package dbft

import (
	"context"
	"sync"
	"time"

	"bitbucket.org/nspcc-dev/dbft/block"
	"bitbucket.org/nspcc-dev/dbft/payload"
	"bitbucket.org/nspcc-dev/dbft/timer"
	"github.com/CityOfZion/neo-go/pkg/util"
	"go.uber.org/zap"
)

type (
	DBFT struct {
		Context
		Config

		*sync.Mutex
		blockPersistTime time.Time
		cache            cache
		recovering       bool
	}

	Service interface {
		Start(context.Context)
		OnTransaction(context.Context, block.Transaction)
		OnReceive(context.Context, payload.ConsensusPayload)
		OnTimeout(context.Context, timer.HV)
	}
)

var _ Service = (*DBFT)(nil)

func New(options ...Option) *DBFT {
	cfg := defaultConfig()

	for _, option := range options {
		option(cfg)
	}

	if err := checkConfig(cfg); err != nil {
		return nil
	}

	d := &DBFT{
		Mutex:  new(sync.Mutex),
		Config: *cfg,
		Context: Context{
			Config: cfg,
		},
	}

	return d
}

func (d *DBFT) addTransaction(ctx context.Context, tx block.Transaction) {
	d.Transactions[tx.Hash()] = tx
	if d.hasAllTransactions() {
		if d.IsPrimary() || d.Context.WatchOnly() {
			return
		}

		if b := d.Context.MakeHeader(); !d.VerifyBlock(b) {
			d.Logger.Warn("can't verify transaction", zap.Stringer("hash", tx.Hash()))
			d.sendChangeView(ctx)

			return
		}

		d.extendTimer(2)
		d.sendPrepareResponse(ctx)
		d.checkPrepare(ctx)
	}
}

func (d *DBFT) Start(ctx context.Context) {
	d.cache = newCache()
	d.InitializeConsensus(0)
	d.start(ctx)
}

func (d *DBFT) InitializeConsensus(view byte) {
	d.reset(view)

	var role string

	switch {
	case d.IsPrimary():
		role = "Primary"
	case d.Context.WatchOnly():
		role = "WatchOnly"
	default:
		role = "Backup"
	}

	d.Logger.Debug("initialize",
		zap.Uint32("height", d.BlockIndex),
		zap.Uint("view", uint(view)),
		zap.Int("index", d.MyIndex),
		zap.String("role", role))

	if d.Context.WatchOnly() {
		return
	}

	if d.IsPrimary() && !d.recovering {
		var (
			span time.Duration
			def  time.Time
		)

		if d.blockPersistTime != def {
			span = d.Timer.Now().Sub(d.blockPersistTime)
		}

		if span >= d.SecondsPerBlock {
			d.changeTimer(0)
		} else {
			d.changeTimer(d.SecondsPerBlock - span)
		}
	} else {
		d.changeTimer(d.SecondsPerBlock << (d.ViewNumber + 1))
	}
}

func (d *DBFT) OnTransaction(ctx context.Context, tx block.Transaction) {
	// d.Logger.Debug("OnTransaction",
	// 	zap.Bool("backup", d.IsBackup()),
	// 	zap.Bool("not_accepting", d.NotAcceptingPayloadsDueToViewChanging()),
	// 	zap.Bool("request_ok", d.RequestSentOrReceived()),
	// 	zap.Bool("response_sent", d.ResponseSent()),
	// 	zap.Bool("block_sent", d.BlockSent()))
	if !d.IsBackup() || d.NotAcceptingPayloadsDueToViewChanging() ||
		!d.RequestSentOrReceived() || d.ResponseSent() || d.BlockSent() {
		return
	}

	h := tx.Hash()
	if _, ok := d.Transactions[h]; ok {
		return
	}

	for i := range d.TransactionHashes {
		if h == d.TransactionHashes[i] {
			d.addTransaction(ctx, tx)
			return
		}
	}
}

// OnTimeout advances state machine as if timeout was fired.
func (d *DBFT) OnTimeout(ctx context.Context, hv timer.HV) {
	if d.Context.WatchOnly() {
		return
	}

	if hv.Height != d.BlockIndex || hv.View != d.ViewNumber {
		d.Logger.Debug("timeout: ignore old timer",
			zap.Uint32("height", hv.Height),
			zap.Uint("view", uint(hv.View)))

		return
	}

	d.Logger.Debug("timeout",
		zap.Uint32("height", hv.Height),
		zap.Uint("view", uint(hv.View)))

	if d.IsPrimary() && !d.RequestSentOrReceived() {
		d.sendPrepareRequest(ctx)
	} else if (d.IsPrimary() && d.RequestSentOrReceived()) || d.IsBackup() {
		if d.CommitSent() {
			d.Logger.Info("send recovery to resend commit")
			d.sendRecoveryRequest(ctx)
			d.changeTimer(d.SecondsPerBlock << 1)
		} else {
			d.sendChangeView(ctx)
		}
	}
}

// OnReceive advances state machine in accordance with msg.
func (d *DBFT) OnReceive(ctx context.Context, msg payload.ConsensusPayload) {
	if int(msg.ValidatorIndex()) >= len(d.Validators) {
		d.Logger.Error("too big validator index", zap.Uint16("from", msg.ValidatorIndex()))
		return
	}

	if msg.Payload() == nil {
		d.Logger.DPanic("invalid message")
		return
	}

	d.Logger.Debug("received message",
		zap.Stringer("type", msg.Type()),
		zap.Uint16("from", msg.ValidatorIndex()),
		zap.Uint32("height", msg.Height()),
		zap.Uint("view", uint(msg.ViewNumber())),
		zap.Uint32("my_height", d.BlockIndex),
		zap.Uint("my_view", uint(d.ViewNumber)))

	if msg.Height() < d.BlockIndex {
		d.Logger.Debug("ignoring old height", zap.Uint32("height", msg.Height()))
		return
	} else if msg.Height() > d.BlockIndex || msg.Height() == d.BlockIndex && msg.ViewNumber() == d.ViewNumber+1 {
		d.Logger.Debug("caching message from future",
			zap.Uint32("height", msg.Height()),
			zap.Uint("view", uint(msg.ViewNumber())),
			zap.Any("cache", d.cache.mail[msg.Height()]))
		d.cache.addMessage(msg)
		return
	} else if msg.ValidatorIndex() > uint16(d.N()) {
		return
	}

	h := d.LastSeenMessage[msg.ValidatorIndex()]
	if h < int64(msg.Height()) {
		d.LastSeenMessage[msg.ValidatorIndex()] = int64(msg.Height())
	}

	switch msg.Type() {
	case payload.ChangeViewType:
		d.onChangeView(ctx, msg)
	case payload.PrepareRequestType:
		d.onPrepareRequest(ctx, msg)
	case payload.PrepareResponseType:
		d.onPrepareResponse(ctx, msg)
	case payload.CommitType:
		d.onCommit(ctx, msg)
	case payload.RecoveryRequestType:
		d.onRecoveryRequest(ctx, msg)
	case payload.RecoveryMessageType:
		d.onRecoveryMessage(ctx, msg)
	default:
		d.Logger.DPanic("wrong message type")
	}
}

// start performs initial operations and returns messages to be sent.
// It must be called after every height or view increment.
func (d *DBFT) start(ctx context.Context) {
	if !d.IsPrimary() {
		if msgs := d.cache.getHeight(d.BlockIndex); msgs != nil {
			for _, m := range msgs.prepare {
				if m.Type() == payload.PrepareRequestType {
					d.onPrepareRequest(ctx, m)
				} else {
					d.onPrepareResponse(ctx, m)
				}
			}

			for _, m := range msgs.chViews {
				d.onChangeView(ctx, m)
			}

			for _, m := range msgs.commit {
				d.onCommit(ctx, m)
			}
		}

		return
	}

	d.sendPrepareRequest(ctx)
}

func (d *DBFT) onPrepareRequest(ctx context.Context, msg payload.ConsensusPayload) {
	// ignore prepareRequest if we had already received it or
	// are in process of changing view
	if d.RequestSentOrReceived() { //|| (d.ViewChanging() && !d.MoreThanFNodesCommittedOrLost()) {
		d.Logger.Debug("ignoring PrepareRequest due to view changing",
			zap.Bool("sor", d.RequestSentOrReceived()),
			zap.Bool("viewChanging", d.ViewChanging()),
			zap.Bool("moreThanF", d.MoreThanFNodesCommittedOrLost()))

		return
	}

	if d.ViewNumber != msg.ViewNumber() {
		d.Logger.Debug("ignoring wrong view number", zap.Uint("view", uint(msg.ViewNumber())))
		return
	} else if uint(msg.ValidatorIndex()) != d.GetPrimaryIndex(d.ViewNumber) {
		d.Logger.Debug("ignoring PrepareRequest from wrong node", zap.Uint16("from", msg.ValidatorIndex()))
		return
	}

	d.extendTimer(2)

	p := msg.GetPrepareRequest()
	if len(p.TransactionHashes()) == 0 {
		d.Logger.Debug("received empty PrepareRequest")
	}

	d.Timestamp = p.Timestamp()
	d.Nonce = p.Nonce()
	d.NextConsensus = p.NextConsensus()
	d.TransactionHashes = p.TransactionHashes()
	d.Transactions = make(map[util.Uint256]block.Transaction)

	d.processMissingTx(ctx)
	d.updateExistingPayloads(msg)
	d.PreparationPayloads[msg.ValidatorIndex()] = msg

	if !d.hasAllTransactions() {
		return
	}

	d.sendPrepareResponse(ctx)
	d.checkPrepare(ctx)
}

func (d *DBFT) processMissingTx(ctx context.Context) {
	missing := make([]util.Uint256, 0, len(d.TransactionHashes))
	txx := make([]block.Transaction, 0, len(d.TransactionHashes))

	for _, h := range d.TransactionHashes {
		if tx := d.GetTx(h); tx == nil {
			missing = append(missing, h)
		} else {
			d.Transactions[h] = tx
			txx = append(txx, tx)
		}
	}

	if len(missing) == 0 {
		if d.NextConsensus != d.GetConsensusAddress(d.GetValidators(txx...)...) {
			d.Logger.Error("invalid nextConsensus")
			d.sendChangeView(ctx)

			return
		}
	} else {
		d.Logger.Warn("missing tx",
			zap.Int("count", len(missing)),
			zap.Any("hashes", missing))
		d.RequestTx(missing...)
	}
}

func (d *DBFT) updateExistingPayloads(msg payload.ConsensusPayload) {
	for i, m := range d.PreparationPayloads {
		if m != nil && m.Type() == payload.PrepareResponseType {
			resp := m.GetPrepareResponse()
			if resp != nil && resp.PreparationHash() != msg.Hash() {
				d.PreparationPayloads[i] = nil
			}
		}
	}

	for i, m := range d.CommitPayloads {
		if m != nil && m.ViewNumber() == d.ViewNumber {
			if header := d.MakeHeader(); header != nil {
				pub := d.Validators[m.ValidatorIndex()]
				if header.Verify(pub, m.GetCommit().Signature()) != nil {
					d.CommitPayloads[i] = nil
					d.Logger.Warn("can't validate commit signature")
				}
			}
		}
	}
}

func (d *DBFT) onPrepareResponse(ctx context.Context, msg payload.ConsensusPayload) {
	if d.ViewNumber != msg.ViewNumber() {
		d.Logger.Debug("ignoring wrong view number", zap.Uint("view", uint(msg.ViewNumber())))
		return
	}

	// ignore PrepareResponse if in process of changing view
	m := d.PreparationPayloads[msg.ValidatorIndex()]
	if m != nil || d.ViewChanging() && !d.MoreThanFNodesCommittedOrLost() {
		d.Logger.Debug("ignoring PrepareResponse because of view changing")
		return
	}

	d.Logger.Debug("prepare response")
	d.PreparationPayloads[msg.ValidatorIndex()] = msg

	if m = d.PreparationPayloads[d.GetPrimaryIndex(d.ViewNumber)]; m != nil {
		req := m.GetPrepareRequest()
		if req == nil {
			d.Logger.DPanic("unexpected nil prepare request")
			return
		}

		prepHash := msg.GetPrepareResponse().PreparationHash()
		if h := m.Hash(); prepHash != h {
			d.PreparationPayloads[msg.ValidatorIndex()] = nil
			d.Logger.Debug("hash mismatch",
				zap.Stringer("primary", h),
				zap.Stringer("received", prepHash))

			return
		}
	}

	d.extendTimer(2)

	if d.RequestSentOrReceived() {
		d.checkPrepare(ctx)
	}
}

func (d *DBFT) onChangeView(ctx context.Context, msg payload.ConsensusPayload) {
	p := msg.GetChangeView()

	if p.NewViewNumber() <= d.ViewNumber {
		d.Logger.Debug("ignoring old ChangeView", zap.Uint("new_view", uint(p.NewViewNumber())))
		d.onRecoveryRequest(ctx, msg)

		return
	}

	if d.CommitSent() {
		d.Logger.Debug("ignoring ChangeView: commit sent")
		return
	}

	m := d.ChangeViewPayloads[msg.ValidatorIndex()]
	if m != nil && p.NewViewNumber() < m.GetChangeView().NewViewNumber() {
		return
	}

	d.ChangeViewPayloads[msg.ValidatorIndex()] = msg
	d.checkChangeView(ctx, p.NewViewNumber())
}

func (d *DBFT) onCommit(ctx context.Context, msg payload.ConsensusPayload) {
	d.extendTimer(4)

	if d.ViewNumber == msg.ViewNumber() {
		header := d.MakeHeader()
		if header == nil {
			d.CommitPayloads[msg.ValidatorIndex()] = msg
		} else {
			pub := d.Validators[msg.ValidatorIndex()]
			if header.Verify(pub, msg.GetCommit().Signature()) == nil {
				d.CommitPayloads[msg.ValidatorIndex()] = msg
				d.checkCommit(ctx)
			} else {
				d.Logger.Warn("can't validate commit signature")
			}
		}

		return
	}

	d.CommitPayloads[msg.ValidatorIndex()] = msg
}

func (d *DBFT) onRecoveryRequest(ctx context.Context, msg payload.ConsensusPayload) {
	if !d.CommitSent() {
		// Limit recoveries to be sent from no more than F nodes
		// TODO replace loop with a single if
		shouldSend := false

		for i := 1; i <= d.F(); i++ {
			ind := (int(msg.ValidatorIndex()) + i) % len(d.Validators)
			if ind == d.MyIndex {
				shouldSend = true
				break
			}
		}

		if !shouldSend {
			return
		}
	}

	d.sendRecoveryMessage(ctx)
}

func (d *DBFT) onRecoveryMessage(ctx context.Context, msg payload.ConsensusPayload) {
	d.Logger.Debug("recovery message received", zap.Any("dump", msg))

	var (
		validPrepResp, validChViews, validCommits int
		validPrepReq, totalPrepReq                int
	)

	recovery := msg.GetRecoveryMessage()
	total := len(d.Validators)

	// isRecovering is always set to false again after OnRecoveryMessageReceived
	d.recovering = true

	defer func() {
		d.Logger.Sugar().Debugf("recovering finished cv=%d/%d preq=%d/%d presp=%d/%d co=%d/%d",
			validChViews, total,
			validPrepReq, totalPrepReq,
			validPrepResp, total,
			validCommits, total)
		d.recovering = false
	}()

	if msg.ViewNumber() > d.ViewNumber {
		if d.CommitSent() {
			return
		}

		for _, m := range recovery.GetChangeViews(msg) {
			validChViews++
			d.onChangeView(ctx, m)
		}
	}

	if msg.ViewNumber() == d.ViewNumber && !(d.ViewChanging() && !d.MoreThanFNodesCommittedOrLost()) && !d.CommitSent() {
		if !d.RequestSentOrReceived() {
			if prepReq := recovery.GetPrepareRequest(msg); prepReq != nil {
				totalPrepReq, validPrepReq = 1, 1

				prepReq.SetValidatorIndex(uint16(d.GetPrimaryIndex(msg.ViewNumber())))
				d.onPrepareRequest(ctx, prepReq)
			} else if d.IsPrimary() {
				d.sendPrepareRequest(ctx)
			}
		}

		for _, m := range recovery.GetPrepareResponses(msg) {
			validPrepResp++
			d.onPrepareResponse(ctx, m)
		}
	}

	if msg.ViewNumber() <= d.ViewNumber {
		// Ensure we know about all commits from lower view numbers.
		for _, m := range recovery.GetCommits(msg) {
			validCommits++
			d.onCommit(ctx, m)
		}
	}
}

func (d *DBFT) changeTimer(delay time.Duration) {
	d.Logger.Debug("reset timer",
		zap.Uint32("h", d.BlockIndex),
		zap.Int("v", int(d.ViewNumber)),
		zap.Duration("delay", delay))
	d.Timer.Reset(timer.HV{Height: d.BlockIndex, View: d.ViewNumber}, delay)
}

func (d *DBFT) extendTimer(count time.Duration) {
	if !d.CommitSent() && !d.ViewChanging() {
		d.Timer.Extend(count * d.SecondsPerBlock / time.Duration(len(d.Validators)-d.F()))
	}
}
