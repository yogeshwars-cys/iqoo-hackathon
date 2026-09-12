# Settlement Risk Policy (sample corpus)

Fictional document, written for demonstrating on-device retrieval. It exists
so the vault has something to index that nobody minds being on a loaner
phone — it contains no credentials, keys or real configuration, and neither
should anything else you use for a demo.

To index it:

    python query.py --index corpus/settlement_risk_policy.md

Then ask the phone about it:

    python query.py "What is the maximum notional order limit?"

---

## 1. Order limits

The matching engine rejects any single order above a hard notional ceiling
before it reaches the book.

    MAX_NOTIONAL_PER_ORDER_USD = 15_000_000.00
    MAX_PORTFOLIO_DRAWDOWN_PCT = 0.045
    GLOBAL_KILL_SWITCH_ACTIVE   = false

Drawdown is evaluated against the previous close, not the intraday high, so
a position that recovers within the session does not trip the stop twice.

## 2. Kill switch

The global kill switch halts new order entry while leaving cancellation
paths open. It is armed automatically when either condition holds:

    - portfolio drawdown exceeds MAX_PORTFOLIO_DRAWDOWN_PCT
    - more than 40 rejected orders occur inside 60 seconds

Re-arming requires two operators. A single desk head cannot clear it alone.

## 3. Retention

    SETTLEMENT_BATCH_INTERVAL_SEC = 30
    LEDGER_RETENTION_YEARS        = 7
    RECONCILIATION_WINDOW_HOURS   = 6

Batches are written every 30 seconds regardless of volume, so a quiet period
still produces an auditable heartbeat in the ledger.

## 4. Escalation

Severity 1 incidents page the on-call risk officer immediately, then the
desk head after 15 minutes without acknowledgement. The reconciliation
window of 6 hours is the outer bound for reporting a settlement break to the
clearing counterparty.

## 5. Offline operation

During an uplink outage the engine continues to evaluate orders against the
limits cached on the device. Orders that pass are queued, not executed, and
the queue is replayed in arrival order once connectivity returns. Nothing in
this section requires network access — which is the property the on-device
vault is meant to demonstrate.
