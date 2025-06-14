;; Bitcoin-Native Payment Platform
;; A comprehensive payment solution leveraging Stacks' Bitcoin integration

;; Constants
(define-constant CONTRACT_OWNER tx-sender)
(define-constant ERR_UNAUTHORIZED (err u100))
(define-constant ERR_INSUFFICIENT_BALANCE (err u101))
(define-constant ERR_PAYMENT_NOT_FOUND (err u102))
(define-constant ERR_PAYMENT_ALREADY_COMPLETED (err u103))
(define-constant ERR_PAYMENT_EXPIRED (err u104))
(define-constant ERR_INVALID_AMOUNT (err u105))
(define-constant ERR_ESCROW_LOCKED (err u106))

;; Data Variables
(define-data-var platform-fee-rate uint u25) ;; 0.25% fee (25 basis points)
(define-data-var min-payment-amount uint u1000) ;; Minimum 1000 satoshis
(define-data-var total-volume uint u0)
(define-data-var payment-counter uint u0)
(define-data-var current-timestamp uint u0) ;; Manual timestamp counter

;; Data Maps
(define-map payments
  uint ;; payment-id
  {
    sender: principal,
    recipient: principal,
    amount: uint,
    fee: uint,
    status: (string-ascii 20),
    created-at: uint,
    expires-at: (optional uint),
    memo: (optional (string-utf8 256)),
    escrow-conditions: (optional (string-ascii 100))
  }
)

(define-map user-balances
  principal
  {
    available: uint,
    locked: uint,
    total-sent: uint,
    total-received: uint
  }
)

(define-map escrow-payments
  uint ;; payment-id
  {
    arbiter: principal,
    released: bool,
    dispute-deadline: uint
  }
)

(define-map recurring-payments
  uint ;; subscription-id
  {
    payer: principal,
    payee: principal,
    amount: uint,
    interval: uint, ;; timestamp intervals between payments
    last-payment: uint,
    active: bool,
    payments-made: uint
  }
)

;; Helper Functions
(define-private (calculate-fee (amount uint))
  (/ (* amount (var-get platform-fee-rate)) u10000)
)

(define-private (get-next-payment-id)
  (let ((current-id (var-get payment-counter)))
    (var-set payment-counter (+ current-id u1))
    (+ current-id u1)
  )
)

(define-private (get-current-time)
  (let ((current-time (var-get current-timestamp)))
    (var-set current-timestamp (+ current-time u1))
    (+ current-time u1)
  )
)

(define-private (update-user-balance (user principal) (amount uint) (is-sender bool))
  (let ((current-balance (default-to 
    {available: u0, locked: u0, total-sent: u0, total-received: u0}
    (map-get? user-balances user))))
    (if is-sender
      (begin
        (asserts! (>= (get available current-balance) amount) ERR_INSUFFICIENT_BALANCE)
        (map-set user-balances user
          (merge current-balance {
            available: (- (get available current-balance) amount),
            total-sent: (+ (get total-sent current-balance) amount)
          }))
        (ok true))
      (begin
        (map-set user-balances user
          (merge current-balance {
            available: (+ (get available current-balance) amount),
            total-received: (+ (get total-received current-balance) amount)
          }))
        (ok true))
    )
  )
)

;; Public Functions

;; Deposit STX to the platform
(define-public (deposit (amount uint))
  (let ((current-balance (default-to 
    {available: u0, locked: u0, total-sent: u0, total-received: u0}
    (map-get? user-balances tx-sender))))
    (try! (stx-transfer? amount tx-sender (as-contract tx-sender)))
    (map-set user-balances tx-sender
      (merge current-balance {
        available: (+ (get available current-balance) amount)
      }))
    (ok amount)
  )
)

;; Withdraw STX from the platform
(define-public (withdraw (amount uint))
  (let ((current-balance (default-to 
    {available: u0, locked: u0, total-sent: u0, total-received: u0}
    (map-get? user-balances tx-sender))))
    (asserts! (>= (get available current-balance) amount) ERR_INSUFFICIENT_BALANCE)
    (try! (as-contract (stx-transfer? amount tx-sender tx-sender)))
    (map-set user-balances tx-sender
      (merge current-balance {
        available: (- (get available current-balance) amount)
      }))
    (ok amount)
  )
)
;; Create instant payment
(define-public (create-payment (recipient principal) (amount uint) (memo (optional (string-utf8 256))))
  (let (
    (payment-id (get-next-payment-id))
    (fee (calculate-fee amount))
    (total-amount (+ amount fee))
    (timestamp (get-current-time))
  )
    (asserts! (>= amount (var-get min-payment-amount)) ERR_INVALID_AMOUNT)
    
    ;; Process payment
    (try! (update-user-balance tx-sender total-amount true))
    (try! (update-user-balance recipient amount false))
    
    ;; Record payment
    (map-set payments payment-id {
      sender: tx-sender,
      recipient: recipient,
      amount: amount,
      fee: fee,
      status: "completed",
      created-at: timestamp,
      expires-at: none,
      memo: memo,
      escrow-conditions: none
    })
    
    ;; Update platform stats
    (var-set total-volume (+ (var-get total-volume) amount))
    
    (ok payment-id)
  )
)
;; Create escrow payment
(define-public (create-escrow-payment 
  (recipient principal) 
  (amount uint) 
  (arbiter principal)
  (deadline uint)
  (memo (optional (string-utf8 256))))
  (let (
    (payment-id (get-next-payment-id))
    (fee (calculate-fee amount))
    (total-amount (+ amount fee))
    (timestamp (get-current-time))
    (sender-balance (default-to 
      {available: u0, locked: u0, total-sent: u0, total-received: u0}
      (map-get? user-balances tx-sender)))
  )
    (asserts! (>= amount (var-get min-payment-amount)) ERR_INVALID_AMOUNT)
    (asserts! (>= (get available sender-balance) total-amount) ERR_INSUFFICIENT_BALANCE)
    (asserts! (> deadline timestamp) ERR_PAYMENT_EXPIRED)
    
    ;; Lock funds in escrow
    (map-set user-balances tx-sender
      (merge sender-balance {
        available: (- (get available sender-balance) total-amount),
        locked: (+ (get locked sender-balance) total-amount)
      }))
    
    ;; Record payment and escrow
    (map-set payments payment-id {
      sender: tx-sender,
      recipient: recipient,
      amount: amount,
      fee: fee,
      status: "escrowed",
      created-at: timestamp,
      expires-at: (some deadline),
      memo: memo,
      escrow-conditions: (some "arbiter-release")
    })
    
    (map-set escrow-payments payment-id {
      arbiter: arbiter,
      released: false,
      dispute-deadline: deadline
    })
    
    (ok payment-id)
  )
)
;; Release escrow payment
(define-public (release-escrow (payment-id uint))
  (let (
    (payment (unwrap! (map-get? payments payment-id) ERR_PAYMENT_NOT_FOUND))
    (escrow (unwrap! (map-get? escrow-payments payment-id) ERR_PAYMENT_NOT_FOUND))
    (sender-balance (default-to 
      {available: u0, locked: u0, total-sent: u0, total-received: u0}
      (map-get? user-balances (get sender payment))))
  )
    (asserts! (or 
      (is-eq tx-sender (get arbiter escrow))
      (is-eq tx-sender (get sender payment))
      (is-eq tx-sender (get recipient payment))) ERR_UNAUTHORIZED)
    (asserts! (is-eq (get status payment) "escrowed") ERR_PAYMENT_ALREADY_COMPLETED)
    (asserts! (not (get released escrow)) ERR_PAYMENT_ALREADY_COMPLETED)
    
    ;; Release funds
    (try! (update-user-balance (get recipient payment) (get amount payment) false))
    
    ;; Update sender balance (unlock and subtract)
    (map-set user-balances (get sender payment)
      (merge sender-balance {
        locked: (- (get locked sender-balance) (+ (get amount payment) (get fee payment))),
        total-sent: (+ (get total-sent sender-balance) (get amount payment))
      }))
    
    ;; Update payment status
    (map-set payments payment-id
      (merge payment {status: "completed"}))
    
    (map-set escrow-payments payment-id
      (merge escrow {released: true}))
    
    (var-set total-volume (+ (var-get total-volume) (get amount payment)))
    (ok true)
  )
)

;; Create recurring payment subscription
(define-public (create-subscription 
  (payee principal) 
  (amount uint) 
  (interval uint))
  (let (
    (subscription-id (get-next-payment-id))
    (timestamp (get-current-time))
  )
    (asserts! (>= amount (var-get min-payment-amount)) ERR_INVALID_AMOUNT)
    (asserts! (> interval u0) ERR_INVALID_AMOUNT)
    
    (map-set recurring-payments subscription-id {
      payer: tx-sender,
      payee: payee,
      amount: amount,
      interval: interval,
      last-payment: timestamp,
      active: true,
      payments-made: u0
    })
    
    (ok subscription-id)
  )
)
;; Process recurring payment
(define-public (process-subscription (subscription-id uint))
  (let (
    (subscription (unwrap! (map-get? recurring-payments subscription-id) ERR_PAYMENT_NOT_FOUND))
    (current-time (get-current-time))
    (payer-balance (default-to 
      {available: u0, locked: u0, total-sent: u0, total-received: u0}
      (map-get? user-balances (get payer subscription))))
    (fee (calculate-fee (get amount subscription)))
    (total-amount (+ (get amount subscription) fee))
  )
    (asserts! (get active subscription) ERR_PAYMENT_ALREADY_COMPLETED)
    (asserts! (>= current-time (+ (get last-payment subscription) (get interval subscription))) ERR_PAYMENT_EXPIRED)
    (asserts! (>= (get available payer-balance) total-amount) ERR_INSUFFICIENT_BALANCE)
    
    ;; Process payment
    (try! (update-user-balance (get payer subscription) total-amount true))
    (try! (update-user-balance (get payee subscription) (get amount subscription) false))
    
    ;; Update subscription
    (map-set recurring-payments subscription-id
      (merge subscription {
        last-payment: current-time,
        payments-made: (+ (get payments-made subscription) u1)
      }))
    
    (var-set total-volume (+ (var-get total-volume) (get amount subscription)))
    (ok true)
  )
)

;; Cancel subscription
(define-public (cancel-subscription (subscription-id uint))
  (let ((subscription (unwrap! (map-get? recurring-payments subscription-id) ERR_PAYMENT_NOT_FOUND)))
    (asserts! (is-eq tx-sender (get payer subscription)) ERR_UNAUTHORIZED)
    (asserts! (get active subscription) ERR_PAYMENT_ALREADY_COMPLETED)
    
    (map-set recurring-payments subscription-id
      (merge subscription {active: false}))
    
    (ok true)
  )
)

;; Manual timestamp increment (for testing/admin)
(define-public (increment-timestamp (blocks uint))
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
    (var-set current-timestamp (+ (var-get current-timestamp) blocks))
    (ok (var-get current-timestamp))
  )
)

;; Read-only functions

(define-read-only (get-payment (payment-id uint))
  (map-get? payments payment-id)
)

(define-read-only (get-user-balance (user principal))
  (default-to 
    {available: u0, locked: u0, total-sent: u0, total-received: u0}
    (map-get? user-balances user))
)

(define-read-only (get-subscription (subscription-id uint))
  (map-get? recurring-payments subscription-id)
)

(define-read-only (get-current-timestamp)
  (var-get current-timestamp)
)

(define-read-only (get-platform-stats)
  {
    total-volume: (var-get total-volume),
    total-payments: (var-get payment-counter),
    platform-fee-rate: (var-get platform-fee-rate),
    min-payment-amount: (var-get min-payment-amount),
    current-timestamp: (var-get current-timestamp)
  }
)

(define-read-only (calculate-payment-fee (amount uint))
  (calculate-fee amount)
)

;; Admin functions (only contract owner)
(define-public (set-platform-fee (new-fee uint))
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
    (asserts! (<= new-fee u1000) ERR_INVALID_AMOUNT) ;; Max 10% fee
    (var-set platform-fee-rate new-fee)
    (ok true)
  )
)

(define-public (set-min-payment (new-min uint))
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
    (var-set min-payment-amount new-min)
    (ok true)
  )
)

;; Emergency functions
(define-public (emergency-refund (payment-id uint))
  (let (
    (payment (unwrap! (map-get? payments payment-id) ERR_PAYMENT_NOT_FOUND))
    (sender-balance (default-to 
      {available: u0, locked: u0, total-sent: u0, total-received: u0}
      (map-get? user-balances (get sender payment))))
  )
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
    (asserts! (is-eq (get status payment) "escrowed") ERR_PAYMENT_ALREADY_COMPLETED)
  
    ;; Refund to sender
    (map-set user-balances (get sender payment)
      (merge sender-balance {
        available: (+ (get available sender-balance) (get amount payment)),
        locked: (- (get locked sender-balance) (+ (get amount payment) (get fee payment)))
      }))
    
    ;; Update payment status
    (map-set payments payment-id
      (merge payment {status: "refunded"}))
    
    (ok true)
  )
)