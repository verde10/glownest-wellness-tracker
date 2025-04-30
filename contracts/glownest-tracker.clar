;; glownest-tracker
;; 
;; This contract manages personal wellness data for the GlowNest platform, including:
;; - Recording sleep metrics (duration, quality, wake/sleep times)
;; - Tracking hydration intake
;; - Logging mindfulness practice sessions
;; - Setting and monitoring personal wellness goals
;; - Tracking achievement streaks and milestones
;; - Permissioned data sharing with healthcare providers
;; - Optional anonymized data contribution to research
;;
;; The contract ensures user data ownership, privacy, and security while
;; providing mechanisms for wellness tracking and improvement.

;; =============================
;; Constants and Error Codes
;; =============================

;; Error codes
(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-INVALID-DATE (err u101))
(define-constant ERR-INVALID-METRICS (err u102))
(define-constant ERR-ALREADY-RECORDED (err u103))
(define-constant ERR-NO-DATA (err u104))
(define-constant ERR-INVALID-GOAL (err u105))
(define-constant ERR-ACCESS-DENIED (err u106))
(define-constant ERR-INVALID-DURATION (err u107))
(define-constant ERR-PROVIDER-NOT-REGISTERED (err u108))
(define-constant ERR-GOAL-NOT-FOUND (err u109))
(define-constant ERR-INVALID-PERMISSIONS (err u110))
(define-constant ERR-STREAK-NOT-FOUND (err u111))

;; Maximum values
(define-constant MAX-SLEEP-HOURS u24)
(define-constant MAX-SLEEP-QUALITY u10)
(define-constant MAX-HYDRATION-ML u10000)
(define-constant MAX-MINDFULNESS-MINUTES u1440) ;; 24 hours max
(define-constant MAX-GOAL-VALUE u10000)
(define-constant MAX-ACCESS-DURATION u30) ;; Max 30 days for temporary access

;; Wellness record types
(define-constant TYPE-SLEEP u1)
(define-constant TYPE-HYDRATION u2)
(define-constant TYPE-MINDFULNESS u3)

;; Goal types
(define-constant GOAL-TYPE-SLEEP-DURATION u1)
(define-constant GOAL-TYPE-SLEEP-QUALITY u2)
(define-constant GOAL-TYPE-HYDRATION u3)
(define-constant GOAL-TYPE-MINDFULNESS u4)

;; Achievement types
(define-constant ACHIEVEMENT-SLEEP-STREAK u1)
(define-constant ACHIEVEMENT-HYDRATION-STREAK u2)
(define-constant ACHIEVEMENT-MINDFULNESS-STREAK u3)
(define-constant ACHIEVEMENT-ALL-METRICS-STREAK u4)

;; =============================
;; Data Maps and Variables
;; =============================

;; Sleep metrics: records daily sleep data
(define-map sleep-records 
  { user: principal, date: uint } 
  { 
    duration-minutes: uint, 
    quality: uint,
    sleep-time: uint,
    wake-time: uint,
    notes: (optional (string-ascii 240))
  }
)

;; Hydration metrics: records daily water intake
(define-map hydration-records
  { user: principal, date: uint }
  {
    total-ml: uint,
    entries: (list 20 { timestamp: uint, amount-ml: uint })
  }
)

;; Mindfulness metrics: records mindfulness sessions
(define-map mindfulness-records
  { user: principal, date: uint }
  {
    total-minutes: uint,
    sessions: (list 10 { timestamp: uint, duration-minutes: uint, type: (string-ascii 50) })
  }
)

;; User wellness goals
(define-map user-goals
  { user: principal, goal-id: uint }
  {
    goal-type: uint,
    target-value: uint,
    start-date: uint,
    end-date: uint,
    is-active: bool,
    is-achieved: bool
  }
)

;; Tracks user's goal counter (for generating goal IDs)
(define-map user-goal-count
  { user: principal }
  { count: uint }
)

;; User achievement tracking
(define-map user-achievements
  { user: principal, achievement-type: uint }
  {
    current-streak: uint,
    longest-streak: uint,
    last-recorded-date: uint,
    milestones-reached: (list 10 { milestone: uint, date-reached: uint })
  }
)

;; Healthcare provider access permissions
(define-map provider-access
  { user: principal, provider: principal }
  {
    granted-at: uint,
    expires-at: uint,
    can-view-sleep: bool,
    can-view-hydration: bool,
    can-view-mindfulness: bool,
    can-view-achievements: bool
  }
)

;; Registered healthcare providers
(define-map registered-providers
  { provider: principal }
  {
    name: (string-ascii 100),
    registration-date: uint,
    is-active: bool
  }
)

;; Anonymized data contribution settings
(define-map research-contribution-settings
  { user: principal }
  {
    contribute-sleep: bool,
    contribute-hydration: bool,
    contribute-mindfulness: bool,
    anonymized-id: (buff 32) ;; Hashed identifier for anonymization
  }
)

;; =============================
;; Private Functions
;; =============================

;; Returns the current blockchain height as a timestamp proxy
(define-private (get-current-time)
  block-height
)

;; Validates date format (expects YYYYMMDD as uint)
(define-private (is-valid-date (date uint))
  (and
    (>= date u19000101)
    (<= date u99991231)
  )
)

;; Validates sleep metrics
(define-private (are-valid-sleep-metrics (duration-minutes uint) (quality uint) (sleep-time uint) (wake-time uint))
  (and
    (<= duration-minutes (* MAX-SLEEP-HOURS u60))
    (<= quality MAX-SLEEP-QUALITY)
    (< sleep-time u2400) ;; 24-hour format validation (0000-2359)
    (< wake-time u2400)
  )
)

;; Validates hydration amount
(define-private (is-valid-hydration (amount-ml uint))
  (<= amount-ml MAX-HYDRATION-ML)
)

;; Validates mindfulness session duration
(define-private (is-valid-mindfulness-duration (duration-minutes uint))
  (<= duration-minutes MAX-MINDFULNESS-MINUTES)
)

;; Generates a new goal ID for a user
(define-private (get-next-goal-id (user principal))
  (let ((current-count (default-to { count: u0 } (map-get? user-goal-count { user: user }))))
    (begin
      (map-set user-goal-count 
        { user: user }
        { count: (+ (get count current-count) u1) }
      )
      (+ (get count current-count) u1)
    )
  )
)

;; Updates the streak for a specific achievement type
(define-private (update-streak (user principal) (achievement-type uint) (date uint))
  (let (
    (current-achievement (map-get? user-achievements { user: user, achievement-type: achievement-type }))
    (default-achievement {
      current-streak: u0,
      longest-streak: u0,
      last-recorded-date: u0,
      milestones-reached: (list)
    })
    (yesterday (- date u1))
  )
    (if (is-none current-achievement)
      ;; First time achievement - start streak at 1
      (map-set user-achievements
        { user: user, achievement-type: achievement-type }
        (merge default-achievement { current-streak: u1, last-recorded-date: date })
      )
      ;; Update existing achievement
      (let (
        (achievement (default-to default-achievement current-achievement))
        (last-date (get last-recorded-date achievement))
        (current-streak (get current-streak achievement))
        (longest-streak (get longest-streak achievement))
        (milestones (get milestones-reached achievement))
      )
        (if (= last-date yesterday)
          ;; Continuing streak
          (let (
            (new-streak (+ current-streak u1))
            (new-longest (if (> new-streak longest-streak) new-streak longest-streak))
            (new-milestones (match (check-milestone new-streak date milestones)
                              milestone-updated milestone-updated
                              milestones))
          )
            (map-set user-achievements
              { user: user, achievement-type: achievement-type }
              {
                current-streak: new-streak,
                longest-streak: new-longest,
                last-recorded-date: date,
                milestones-reached: new-milestones
              }
            )
          )
          ;; Streak broken if not yesterday, start new streak
          (map-set user-achievements
            { user: user, achievement-type: achievement-type }
            {
              current-streak: u1,
              longest-streak: longest-streak,
              last-recorded-date: date,
              milestones-reached: milestones
            }
          )
        )
      )
    )
    (ok true)
  )
)

;; Check if a new milestone has been reached and update milestones if so
(define-private (check-milestone (streak uint) (date uint) (milestones (list 10 { milestone: uint, date-reached: uint })))
  (let (
    (milestone-values (list u7 u30 u90 u180 u365))
  )
    (match (find-milestone milestone-values streak)
      milestone-value (as-max-len? (append milestones { milestone: milestone-value, date-reached: date }) u10)
      milestones
    )
  )
)

;; Find the milestone value that matches the current streak
(define-private (find-milestone (milestone-values (list 5 uint)) (streak uint))
  (match (filter is-milestone-match milestone-values)
    matched-list (match (element-at matched-list u0) milestone-value (some milestone-value) none)
    none
  )
  (define-private (is-milestone-match (value uint))
    (= value streak)
  )
)

;; Check if a user has authorized a provider to access data
(define-private (is-provider-authorized (user principal) (provider principal) (access-type (string-ascii 20)))
  (let ((access-info (map-get? provider-access { user: user, provider: provider })))
    (and 
      (is-some access-info)
      (let ((info (unwrap-panic access-info)))
        (and
          (>= (get-current-time) (get granted-at info))
          (<= (get-current-time) (get expires-at info))
          (match access-type
            "sleep" (get can-view-sleep info)
            "hydration" (get can-view-hydration info)
            "mindfulness" (get can-view-mindfulness info)
            "achievements" (get can-view-achievements info)
            false
          )
        )
      )
    )
  )
)

;; =============================
;; Read-Only Functions
;; =============================

;; Get sleep records for a specific date
(define-read-only (get-sleep-record (user principal) (date uint))
  (let ((data (map-get? sleep-records { user: user, date: date })))
    (if (and (is-some data) (or (is-eq tx-sender user) (is-provider-authorized user tx-sender "sleep")))
      (ok (unwrap-panic data))
      ERR-NO-DATA
    )
  )
)

;; Get hydration records for a specific date
(define-read-only (get-hydration-record (user principal) (date uint))
  (let ((data (map-get? hydration-records { user: user, date: date })))
    (if (and (is-some data) (or (is-eq tx-sender user) (is-provider-authorized user tx-sender "hydration")))
      (ok (unwrap-panic data))
      ERR-NO-DATA
    )
  )
)

;; Get mindfulness records for a specific date
(define-read-only (get-mindfulness-record (user principal) (date uint))
  (let ((data (map-get? mindfulness-records { user: user, date: date })))
    (if (and (is-some data) (or (is-eq tx-sender user) (is-provider-authorized user tx-sender "mindfulness")))
      (ok (unwrap-panic data))
      ERR-NO-DATA
    )
  )
)

;; Get specific goal information
(define-read-only (get-goal (user principal) (goal-id uint))
  (let ((goal (map-get? user-goals { user: user, goal-id: goal-id })))
    (if (and (is-some goal) (or (is-eq tx-sender user) (is-provider-authorized user tx-sender "achievements")))
      (ok (unwrap-panic goal))
      ERR-GOAL-NOT-FOUND
    )
  )
)

;; Get streak information for an achievement type
(define-read-only (get-achievement-streak (user principal) (achievement-type uint))
  (let ((streak-data (map-get? user-achievements { user: user, achievement-type: achievement-type })))
    (if (and (is-some streak-data) (or (is-eq tx-sender user) (is-provider-authorized user tx-sender "achievements")))
      (ok (unwrap-panic streak-data))
      ERR-STREAK-NOT-FOUND
    )
  )
)

;; Check if a provider is registered and active
(define-read-only (is-provider-active (provider principal))
  (let ((provider-info (map-get? registered-providers { provider: provider })))
    (if (is-some provider-info)
      (get is-active (unwrap-panic provider-info))
      false
    )
  )
)

;; Get provider access settings
(define-read-only (get-provider-access (user principal) (provider principal))
  (if (or (is-eq tx-sender user) (is-eq tx-sender provider))
    (let ((access-info (map-get? provider-access { user: user, provider: provider })))
      (if (is-some access-info)
        (ok (unwrap-panic access-info))
        ERR-NO-DATA
      )
    )
    ERR-NOT-AUTHORIZED
  )
)

;; Get research contribution settings
(define-read-only (get-research-settings (user principal))
  (if (is-eq tx-sender user)
    (let ((settings (map-get? research-contribution-settings { user: user })))
      (if (is-some settings)
        (ok (unwrap-panic settings))
        (ok {
          contribute-sleep: false,
          contribute-hydration: false,
          contribute-mindfulness: false,
          anonymized-id: 0x0000000000000000000000000000000000000000000000000000000000000000
        })
      )
    )
    ERR-NOT-AUTHORIZED
  )
)

;; =============================
;; Public Functions
;; =============================

;; Record sleep metrics for a specific date
(define-public (record-sleep (date uint) (duration-minutes uint) (quality uint) (sleep-time uint) (wake-time uint) (notes (optional (string-ascii 240))))
  (let ((user tx-sender))
    (if (not (is-valid-date date))
      ERR-INVALID-DATE
      (if (not (are-valid-sleep-metrics duration-minutes quality sleep-time wake-time))
        ERR-INVALID-METRICS
        (if (is-some (map-get? sleep-records { user: user, date: date }))
          ERR-ALREADY-RECORDED
          (begin
            ;; Record sleep data
            (map-set sleep-records
              { user: user, date: date }
              { 
                duration-minutes: duration-minutes,
                quality: quality,
                sleep-time: sleep-time,
                wake-time: wake-time,
                notes: notes
              }
            )
            ;; Update sleep streak
            (update-streak user ACHIEVEMENT-SLEEP-STREAK date)
            ;; Check for goal achievements
            (check-sleep-goals user date duration-minutes quality)
            ;; Check all-metrics streak if hydration and mindfulness also recorded today
            (try! (check-all-metrics-streak user date))
            (ok true)
          )
        )
      )
    )
  )
)

;; Record hydration for a specific date
(define-public (record-hydration (date uint) (amount-ml uint))
  (let (
    (user tx-sender)
    (current-time (get-current-time))
  )
    (if (not (is-valid-date date))
      ERR-INVALID-DATE
      (if (not (is-valid-hydration amount-ml))
        ERR-INVALID-METRICS
        (let (
          (existing-record (map-get? hydration-records { user: user, date: date }))
          (default-record {
            total-ml: u0,
            entries: (list)
          })
        )
          (begin
            ;; Update hydration records
            (map-set hydration-records
              { user: user, date: date }
              {
                total-ml: (+ (get total-ml (default-to default-record existing-record)) amount-ml),
                entries: (as-max-len? 
                  (append 
                    (get entries (default-to default-record existing-record))
                    { timestamp: current-time, amount-ml: amount-ml }
                  ) 
                  u20
                )
              }
            )
            ;; Update hydration streak if first entry today
            (if (is-none existing-record)
              (update-streak user ACHIEVEMENT-HYDRATION-STREAK date)
              (ok true)
            )
            ;; Check for goal achievements
            (check-hydration-goals user date (+ (get total-ml (default-to default-record existing-record)) amount-ml))
            ;; Check all-metrics streak if sleep and mindfulness also recorded today
            (try! (check-all-metrics-streak user date))
            (ok true)
          )
        )
      )
    )
  )
)

;; Record mindfulness session
(define-public (record-mindfulness (date uint) (duration-minutes uint) (practice-type (string-ascii 50)))
  (let (
    (user tx-sender)
    (current-time (get-current-time))
  )
    (if (not (is-valid-date date))
      ERR-INVALID-DATE
      (if (not (is-valid-mindfulness-duration duration-minutes))
        ERR-INVALID-DURATION
        (let (
          (existing-record (map-get? mindfulness-records { user: user, date: date }))
          (default-record {
            total-minutes: u0,
            sessions: (list)
          })
        )
          (begin
            ;; Update mindfulness records
            (map-set mindfulness-records
              { user: user, date: date }
              {
                total-minutes: (+ (get total-minutes (default-to default-record existing-record)) duration-minutes),
                sessions: (as-max-len?
                  (append
                    (get sessions (default-to default-record existing-record))
                    { timestamp: current-time, duration-minutes: duration-minutes, type: practice-type }
                  )
                  u10
                )
              }
            )
            ;; Update mindfulness streak if first entry today
            (if (is-none existing-record)
              (update-streak user ACHIEVEMENT-MINDFULNESS-STREAK date)
              (ok true)
            )
            ;; Check for goal achievements
            (check-mindfulness-goals user date (+ (get total-minutes (default-to default-record existing-record)) duration-minutes))
            ;; Check all-metrics streak if sleep and hydration also recorded today
            (try! (check-all-metrics-streak user date))
            (ok true)
          )
        )
      )
    )
  )
)

;; Create a new wellness goal
(define-public (create-goal (goal-type uint) (target-value uint) (start-date uint) (end-date uint))
  (let (
    (user tx-sender)
    (goal-id (get-next-goal-id user))
  )
    (if (not (and (is-valid-date start-date) (is-valid-date end-date) (>= end-date start-date)))
      ERR-INVALID-DATE
      (if (or (< goal-type u1) (> goal-type u4) (> target-value MAX-GOAL-VALUE))
        ERR-INVALID-GOAL
        (begin
          (map-set user-goals
            { user: user, goal-id: goal-id }
            {
              goal-type: goal-type,
              target-value: target-value,
              start-date: start-date,
              end-date: end-date,
              is-active: true,
              is-achieved: false
            }
          )
          (ok goal-id)
        )
      )
    )
  )
)

;; Deactivate a goal
(define-public (deactivate-goal (goal-id uint))
  (let (
    (user tx-sender)
    (goal (map-get? user-goals { user: user, goal-id: goal-id }))
  )
    (if (is-none goal)
      ERR-GOAL-NOT-FOUND
      (begin
        (map-set user-goals
          { user: user, goal-id: goal-id }
          (merge (unwrap-panic goal) { is-active: false })
        )
        (ok true)
      )
    )
  )
)

;; Register as a healthcare provider
(define-public (register-provider (name (string-ascii 100)))
  (let (
    (provider tx-sender)
    (current-time (get-current-time))
  )
    (map-set registered-providers
      { provider: provider }
      {
        name: name,
        registration-date: current-time,
        is-active: true
      }
    )
    (ok true)
  )
)

;; Grant access to a healthcare provider
(define-public (grant-provider-access 
  (provider principal) 
  (duration-days uint) 
  (can-view-sleep bool) 
  (can-view-hydration bool) 
  (can-view-mindfulness bool) 
  (can-view-achievements bool)
)
  (let (
    (user tx-sender)
    (current-time (get-current-time))
  )
    (if (not (is-provider-active provider))
      ERR-PROVIDER-NOT-REGISTERED
      (if (> duration-days MAX-ACCESS-DURATION)
        ERR-INVALID-DURATION
        (begin
          (map-set provider-access
            { user: user, provider: provider }
            {
              granted-at: current-time,
              expires-at: (+ current-time (* duration-days u144)), ;; ~1 day = 144 blocks
              can-view-sleep: can-view-sleep,
              can-view-hydration: can-view-hydration,
              can-view-mindfulness: can-view-mindfulness,
              can-view-achievements: can-view-achievements
            }
          )
          (ok true)
        )
      )
    )
  )
)

;; Revoke access from a healthcare provider
(define-public (revoke-provider-access (provider principal))
  (let (
    (user tx-sender)
    (access-info (map-get? provider-access { user: user, provider: provider }))
  )
    (if (is-none access-info)
      ERR-NO-DATA
      (begin
        (map-delete provider-access { user: user, provider: provider })
        (ok true)
      )
    )
  )
)

;; Update research contribution settings
(define-public (update-research-settings 
  (contribute-sleep bool) 
  (contribute-hydration bool) 
  (contribute-mindfulness bool)
)
  (let (
    (user tx-sender)
    (current-settings (map-get? research-contribution-settings { user: user }))
    (default-settings {
      contribute-sleep: false,
      contribute-hydration: false,
      contribute-mindfulness: false,
      anonymized-id: 0x0000000000000000000000000000000000000000000000000000000000000000
    })
  )
    (map-set research-contribution-settings
      { user: user }
      {
        contribute-sleep: contribute-sleep,
        contribute-hydration: contribute-hydration,
        contribute-mindfulness: contribute-mindfulness,
        anonymized-id: (if (is-some current-settings) 
                         (get anonymized-id (unwrap-panic current-settings))
                         (hash160 (concat (to-consensus-buff? user) (to-consensus-buff? (get-current-time)))))
      }
    )
    (ok true)
  )
)

;; =============================
;; Helper Functions for Goals and Achievements
;; =============================

;; Check if any sleep goals have been achieved
(define-private (check-sleep-goals (user principal) (date uint) (duration-minutes uint) (quality uint))
  (begin
    (map check-sleep-goal (get-active-goals user date GOAL-TYPE-SLEEP-DURATION))
    (map check-sleep-quality-goal (get-active-goals user date GOAL-TYPE-SLEEP-QUALITY))
    (ok true)
  )
  
  ;; Helper to check sleep duration goals
  (define-private (check-sleep-goal (goal-info { goal-id: uint, target-value: uint }))
    (if (>= duration-minutes (get target-value goal-info))
      (mark-goal-achieved user (get goal-id goal-info))
      true
    )
  )
  
  ;; Helper to check sleep quality goals
  (define-private (check-sleep-quality-goal (goal-info { goal-id: uint, target-value: uint }))
    (if (>= quality (get target-value goal-info))
      (mark-goal-achieved user (get goal-id goal-info))
      true
    )
  )
)

;; Check if any hydration goals have been achieved
(define-private (check-hydration-goals (user principal) (date uint) (total-ml uint))
  (begin
    (map check-hydration-goal (get-active-goals user date GOAL-TYPE-HYDRATION))
    (ok true)
  )
  
  ;; Helper to check hydration goals
  (define-private (check-hydration-goal (goal-info { goal-id: uint, target-value: uint }))
    (if (>= total-ml (get target-value goal-info))
      (mark-goal-achieved user (get goal-id goal-info))
      true
    )
  )
)

;; Check if any mindfulness goals have been achieved
(define-private (check-mindfulness-goals (user principal) (date uint) (total-minutes uint))
  (begin
    (map check-mindfulness-goal (get-active-goals user date GOAL-TYPE-MINDFULNESS))
    (ok true)
  )
  
  ;; Helper to check mindfulness goals
  (define-private (check-mindfulness-goal (goal-info { goal-id: uint, target-value: uint }))
    (if (>= total-minutes (get target-value goal-info))
      (mark-goal-achieved user (get goal-id goal-info))
      true
    )
  )
)

;; Check if all metrics have been recorded for the day to update the all-metrics streak
(define-private (check-all-metrics-streak (user principal) (date uint))
  (let (
    (has-sleep (is-some (map-get? sleep-records { user: user, date: date })))
    (has-hydration (is-some (map-get? hydration-records { user: user, date: date })))
    (has-mindfulness (is-some (map-get? mindfulness-records { user: user, date: date })))
  )
    (if (and has-sleep has-hydration has-mindfulness)
      (update-streak user ACHIEVEMENT-ALL-METRICS-STREAK date)
      (ok true)
    )
  )
)

;; Get active goals for a user of a specific type
(define-private (get-active-goals (user principal) (date uint) (goal-type uint))
  (filter 
    filter-active-goals 
    (map extract-goal-info
      (unwrap! (map-keys-filter? 
        user-goals {user: user} 
        { goal-type: goal-type, is-active: true, is-achieved: false }) 
        (list)))
  )
  
  (define-private (filter-active-goals (goal-info { goal-id: uint, target-value: uint }))
    true
  )
  
  (define-private (extract-goal-info (key { user: principal, goal-id: uint }))
    (let (
      (goal (unwrap-panic (map-get? user-goals { user: (get user key), goal-id: (get goal-id key) })))
    )
      { 
        goal-id: (get goal-id key),
        target-value: (get target-value goal)
      }
    )
  )
)

;; Mark a goal as achieved
(define-private (mark-goal-achieved (user principal) (goal-id uint))
  (let (
    (goal (map-get? user-goals { user: user, goal-id: goal-id }))
  )
    (if (is-some goal)
      (map-set user-goals
        { user: user, goal-id: goal-id }
        (merge (unwrap-panic goal) { is-achieved: true })
      )
      false
    )
  )
)