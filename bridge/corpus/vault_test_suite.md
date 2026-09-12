# Enterprise Core Infrastructure & Risk Policy (Demo Suite)

## 1. Execution & Order Risk Limits
The matching engine evaluates every inbound transaction against strict algorithmic thresholds before writing to the ledger:

    MAX_NOTIONAL_PER_ORDER_USD = 15_000_000.00
    MAX_PORTFOLIO_DRAWDOWN_PCT = 0.045
    GLOBAL_KILL_SWITCH_ACTIVE   = false
    ORDER_BURST_CAP_PER_SECOND = 2500

Drawdown is measured strictly against the previous session close. If intraday recovery occurs, the threshold is not re-triggered within the same active cycle.

## 2. Automated Circuit Breakers
The automated kill switch engages and cancels all open resting limits when any of the following triggers are met:
- Cumulative drawdown breaches MAX_PORTFOLIO_DRAWDOWN_PCT (4.5%).
- More than 40 rejected orders occur inside 60 seconds.
- An anomalous clock skew greater than 250 microseconds is detected between gateways.

Re-arming the kill switch requires cryptographic authorization from two independent operators. A single desk head cannot reset the system alone.

## 3. Data Retention & Settlement Timing
All transaction batches conform to strict temporal and regulatory guidelines:

    SETTLEMENT_BATCH_INTERVAL_SEC = 30
    LEDGER_RETENTION_YEARS        = 7
    RECONCILIATION_WINDOW_HOURS   = 6
    ARCHIVE_COMPRESSION_CODEC     = "zstd-level-19"

Batches are committed every 30 seconds even during zero-volume periods to ensure continuous cryptographic audit trails.

## 4. Incident Response & Escalation Protocol
- Severity 1 (Critical Outage): Pages the on-call chief risk officer immediately via PagerDuty. If unacknowledged within 15 minutes, escalation alerts the global desk head.
- Severity 2 (Degraded Performance): Dispatches an alert to the primary reliability engineering channel within 30 minutes.
- The reconciliation window of 6 hours represents the hard regulatory deadline for reporting settlement breaks to counterparties.

## 5. Air-Gapped & Offline Fallback Mode
In the event of an uplink failure or severed wide-area network:
- The local node transitions to Autonomous Cached Mode.
- Incoming requests are validated exclusively against on-device cached parameters.
- Validated records are appended to an immutable append-only SQLite log on the handset.
- No network transmission or external data egress is attempted until an authenticated peer link is re-established.
