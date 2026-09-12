# Platform Reliability & On-Call Runbook (Demo Suite)

## 1. Alerting Thresholds
The reliability platform pages on-call engineers when service-level indicators cross the following bounds:

    ERROR_RATE_PAGE_THRESHOLD_PCT   = 2.0
    P99_LATENCY_PAGE_THRESHOLD_MS   = 1800
    QUEUE_DEPTH_PAGE_THRESHOLD      = 50_000
    SYNTHETIC_CHECK_INTERVAL_SEC    = 30

A page fires only after three consecutive synthetic check failures, so a single transient blip during a deploy does not wake anyone.

## 2. Automated Kill Switch for Bad Deploys
The deployment pipeline engages its own automated kill switch and rolls back the active release when any of the following triggers are met:
- Error rate breaches ERROR_RATE_PAGE_THRESHOLD_PCT (2.0%) within 5 minutes of a rollout completing.
- More than 25 pod crash-loops occur inside 60 seconds across the fleet.
- The canary cohort's latency exceeds twice the baseline for 3 consecutive synthetic checks.

Re-arming this kill switch after an automatic rollback requires a single on-call engineer's acknowledgement in the incident channel — unlike a manual production freeze, which needs sign-off from the reliability lead.

## 3. Severity Levels & Escalation
- Severity 1 (full outage): Pages the on-call primary immediately via PagerDuty. If unacknowledged within 5 minutes, escalation pages the secondary; if still unacknowledged after 10 minutes total, the reliability lead is paged directly.
- Severity 2 (degraded performance, partial outage): Pages the on-call primary via PagerDuty with a 20-minute acknowledgement window before escalating.
- Severity 3 (minor, no customer impact): Posted to the reliability channel, no page.
- Every Severity 1 incident requires a postmortem published within 5 business days, regardless of root cause.

## 4. Data Pipeline Retention
Telemetry and log data feeding the alerting system are retained on the following schedule:

    RAW_METRIC_RETENTION_DAYS      = 13
    AGGREGATED_METRIC_RETENTION_MONTHS = 18
    INCIDENT_LOG_RETENTION_YEARS   = 3

Raw, per-request traces are the most expensive to store and are the first tier discarded; aggregated rollups survive far longer because they are what postmortems actually cite.

## 5. Maintenance Windows
Planned maintenance that can cause a customer-visible blip is restricted to a standing weekly window, never announced less than 48 hours in advance. Emergency maintenance to address an active Severity 1 or 2 is exempt from the advance-notice requirement but still requires the reliability lead's real-time approval before the change is applied, not after.
