# Employee Device & Data Handling Policy (Demo Suite)

## 1. Device Enrollment
Any device used to access internal systems must be enrolled in mobile device management before first use:

    ENROLLMENT_GRACE_PERIOD_DAYS     = 3
    MIN_OS_VERSION_ANDROID           = 12
    MIN_OS_VERSION_IOS                = 16
    PASSCODE_MIN_LENGTH               = 6

Devices that fall out of the minimum OS version are given ENROLLMENT_GRACE_PERIOD_DAYS (3 days) of warnings before internal app access is automatically revoked, not disabled immediately — abrupt revocation during business hours has historically caused more support tickets than the security benefit justified.

## 2. Data Classification & Local Storage
Internal data is classified into three tiers, and only two are ever permitted to touch an employee-owned device:
- Public: no restriction.
- Internal: may be cached locally, must be encrypted at rest using the platform keystore, never a custom cipher.
- Restricted: must never be stored on an employee-owned device in any form, including screenshots, clipboard history, or offline caches. Restricted data may only be viewed through a remote session that leaves no local copy.

## 3. Offboarding & Remote Wipe
When an employee's access is revoked, the device management system issues a selective wipe of the managed work profile:

    WIPE_INITIATION_SLA_HOURS  = 1
    FULL_WIPE_ESCALATION_DAYS  = 14
    DATA_RETENTION_POST_WIPE_DAYS = 30

A selective wipe must be initiated within WIPE_INITIATION_SLA_HOURS (1 hour) of an offboarding ticket closing. If the device does not check in and confirm the wipe within FULL_WIPE_ESCALATION_DAYS (14 days), the case escalates to a full-device wipe request, which requires the device owner's manager to approve given it also removes personal data on a personally-owned device.

## 4. Incident Reporting for Lost or Stolen Devices
A lost or stolen device enrolled in device management must be reported within 2 hours of discovery. Security immediately issues a remote lock and begins wipe initiation on the same SLA as a standard offboarding wipe. Devices that were storing Restricted-tier data at the time of loss trigger a mandatory security review regardless of whether the wipe succeeds, because the review's purpose is establishing what left the device before the lock took effect, not just cleaning up after.

## 5. Data Retention on Company Systems
Data retention for company-held records is governed separately from device-local storage and does not follow the device wipe timelines above:

    EMAIL_RETENTION_YEARS       = 5
    HR_RECORD_RETENTION_YEARS   = 7
    ACCESS_LOG_RETENTION_MONTHS = 18

These figures apply to centrally-held systems only; nothing in this section changes what may or may not be cached on a device, which is governed entirely by Section 2's data classification rules.
