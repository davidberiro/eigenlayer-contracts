## DelegationManager

| File | Type | Proxy |
| -------- | -------- | -------- |
| [`DelegationManager.sol`](../../src/contracts/core/DelegationManager.sol) | Singleton | Transparent proxy |

The primary functions of the `DelegationManager` are (i) to allow Stakers to delegate/undelegate to/from Operators, (ii) handle withdrawals and withdrawal processing for assets in both the `StrategyManager` and `EigenPodManager`, and (iii) to manage accounting around slashing for Stakers and Operators.

The `DelegationManager` is the intersection between the two sides of the protocol:
* It handles share burning directives sent by the `AllocationManager` when Operators are slashed by AVSs.
* It tracks share/delegation accounting changes when Stakers deposit assets using the `StrategyManager` and `EigenPodManager` (or withdraw them via the `DelegationManager`).

Whether a Staker is currently delegated to an Operator or not, the `DelegationManager` keeps track of a Staker's withdrawable shares by tracking their "deposit scaling factor" as well as their "slashingFactor" for the strategy. These values allow the `DelegationManager` to account for slashing, serving as the primary conversion vehicle between a Staker's raw deposited assets and the amount they can actually delegate or withdraw. 

This contract handles 3 types of shares:
1. delegated/operator shares: The delegated shares of an operator read from 
Exists in storage: `DelegationManager.operatorShares`
2. deposit shares: The amount of Strategy shares they have been awarded from depositing the actual underlying asset.
Exists in storage: `StrategyManager.stakerDepositShares` and `EigenPodManager.podOwnerDepositShares`
3. withdrawableShares: How many shares a staker can withdraw given their deposit shares less any slashing that has occurred to their stake.
Does not exist in storage but is read from `DelegationManager.getWithdrawableShares`

See [`docs/core/SharesAccounting.md`](./SharesAccounting.md) for details.


#### High-level Concepts

This document organizes methods according to the following themes (click each to be taken to the relevant section):
* [Becoming an Operator](#becoming-an-operator)
* [Delegating to an Operator](#delegating-to-an-operator)
* [Undelegating and Withdrawing](#undelegating-and-withdrawing)
* [Accounting](#accounting)
* [Slashing](#slashing)
* [System Configuration](#system-configuration)

#### Important state variables

*Delegation and Share Accounting:*

```solidity
/// @notice Returns the `operator` a `staker` is delgated to, or address(0) if not delegated.
/// Note: operators are delegated to themselves
mapping(address staker => address operator) public delegatedTo;

/**
 * @notice Tracks the current balance of shares an `operator` is delegated according to each `strategy`. 
 * Updated by both the `StrategyManager` and `EigenPodManager` when a staker's delegatable balance changes,
 * and by the `AllocationManager` when the `operator` is slashed.
 *
 * @dev The following invariant should hold for each `strategy`:
 *
 * operatorShares[operator] = sum(withdrawable shares of all stakers delegated to operator)
 */
mapping(address operator => mapping(IStrategy strategy => uint256 shares)) public operatorShares;

/// @notice Returns the scaling factor applied to a `staker` for a given `strategy`
mapping(address staker => mapping(IStrategy strategy => DepositScalingFactor)) internal _depositScalingFactor;

/// @notice Contains history of the total cumulative staker withdrawals for an operator and a given strategy.
/// Used to calculate burned StrategyManager shares when an operator is slashed.
/// @dev Stores scaledShares instead of total withdrawn shares to track current slashable shares, dependent on the maxMagnitude
mapping(address operator => mapping(IStrategy strategy => Snapshots.DefaultZeroHistory)) internal
    _cumulativeScaledSharesHistory;
```

*Withdrawal Processing:*


```solidity
/// @notice Minimum withdrawal delay in blocks until a queued withdrawal can be completed.
uint32 internal immutable MIN_WITHDRAWAL_DELAY_BLOCKS;

/// @dev Returns whether a withdrawal is pending for a given `withdrawalRoot`.
/// @dev This variable will be deprecated in the future, values should only be read or deleted.
mapping(bytes32 withdrawalRoot => bool pending) public pendingWithdrawals;

/// @notice Returns a list of queued withdrawals for a given `staker`.
/// @dev Entrys are removed when the withdrawal is completed.
/// @dev This variable only reflects withdrawals that were made after the slashing release.
mapping(address staker => EnumerableSet.Bytes32Set withdrawalRoots) internal _stakerQueuedWithdrawalRoots;

/// @notice Returns the details of a queued withdrawal for a given `staker` and `withdrawalRoot`.
/// @dev This variable only reflects withdrawals that were made after the slashing release.
mapping(bytes32 withdrawalRoot => Withdrawal withdrawal) public queuedWithdrawals;
```

*Burning of Operator Shares:*

```solidity
/// @notice Contains history of the total cumulative staker withdrawals for an operator and a given strategy.
/// Used to calculate burned StrategyManager shares when an operator is slashed.
/// @dev Stores scaledShares instead of total withdrawn shares to track current slashable shares, dependent on the maxMagnitude
mapping(address operator => mapping(IStrategy strategy => Snapshots.DefaultZeroHistory)) internal
    _cumulativeScaledSharesHistory;
```

<!-- * A similar mapping exists in the `StrategyManager`, but the `DelegationManager` additionally tracks beacon chain ETH delegated via the `EigenPodManager`. The "beacon chain ETH" strategy gets its own special address for this mapping: `0xbeaC0eeEeeeeEEeEeEEEEeeEEeEeeeEeeEEBEaC0`. -->

#### Helpful definitions

* `isDelegated(address staker) -> (bool)`
    * True if `delegatedTo[staker] != address(0)`
* `isOperator(address operator) -> (bool)` 
    * True if `delegatedTo[operator] == operator`
* `beaconChainETHStrategy` is not an actually deployed Strategy contract. It is a hardcoded value that represents the shares in the `EigenPodManager` that helps to unify some of the logic surrounding operator shares, withdrawals, and slashing.
---

### Becoming an Operator

Operators interact with the following functions to become an Operator:

* [`DelegationManager.registerAsOperator`](#registerasoperator)
* [`DelegationManager.modifyOperatorDetails`](#modifyoperatordetails)
* [`DelegationManager.updateOperatorMetadataURI`](#updateoperatormetadatauri)

#### `registerAsOperator`

```solidity
function registerAsOperator(
    address initDelegationApprover,
    uint32 allocationDelay,
    string calldata metadataURI
) external;
```

Registers the caller as an Operator in EigenLayer. The new Operator provides the following input parameters:
* `address initDelegationApprover`: if set to non-zero address, this address must sign and approve new delegation from Stakers to this Operator *(optional)*
* `uint32 allocationDelay`: configures the delay on allocations(in blocks) to take effect in the AllocationManager. This is stored and configurable in the AllocationManager but is included in here in the operator registration interface as convenience.
More details on allocations and unique security can be found in the [`AllocationManager`](./AllocationManager.md)
* `string calldata metadataURI`: emits this input in the event `OperatorMetadataURIUpdated`. Does not store the value anywhere.

`registerAsOperator` cements the Operator's delegation approver and allocation delay in storage, and self-delegates the Operator to themselves - permanently marking the caller as an Operator. They cannot "deregister" as an Operator - however, they can exit the system by withdrawing their funds via `queueWithdrawals`.

*Effects*:
* Sets `OperatorDetails` for the Operator in question. 2 fields in the struct are deprecated and the only value used is the delegationApprover which is passed in as calldata
* Delegates the Operator to itself
* If the Operator has deposit shares in the `EigenPodManager`, the `DelegationManager` adds this shares amount to the Operator's shares for the beaconChainETHstrategy.
* For each of the strategies in the `StrategyManager`, if the Operator holds deposit shares in that strategy they are added to the Operator's shares under the corresponding strategy.
* For each `Strategy` including the beaconChainETHStrategy that increased delegated shares, update the depositScalingFactor for the Operator.

*Requirements*:
* Caller MUST NOT already be delegated
* Pause status MUST NOT be set: `PAUSED_NEW_DELEGATION`
* `slashingFactor` for the strategy MUST be non-zero

#### `modifyOperatorDetails`

```solidity
function modifyOperatorDetails(address operator, address newDelegationApprover) external checkCanCall(operator)
```

Allows an Operator to update their stored `delegationApprover`.

*Requirements*:
* `address operator` MUST already be an Operator.
* Caller MUST have permission to call on behalf of the Operator.

#### `updateOperatorMetadataURI`

```solidity
function updateOperatorMetadataURI(address operator, string calldata metadataURI) external checkCanCall(operator)
```

Allows an Operator to emit an `OperatorMetadataURIUpdated` event. No other state changes occur.

*Requirements*:
* `address operator` MUST already be an Operator.
* Caller MUST have permission to call on behalf of the Operator.

---

### Delegating to an Operator

Stakers interact with the following functions to delegate their shares to an Operator:

* [`DelegationManager.delegateTo`](#delegateto)

#### `delegateTo`

```solidity
function delegateTo(
    address operator, 
    SignatureWithExpiry memory approverSignatureAndExpiry, 
    bytes32 approverSalt
) 
    external
```

Allows the caller (a Staker) to delegate their shares to an Operator. Delegation is all-or-nothing: when a Staker delegates to an Operator, they delegate ALL their deposit shares. For each strategy the Staker has deposit shares in, the `DelegationManager` will update the Operator's corresponding delegated share amounts.

*Effects*:
* Records the Staker as being delegated to the Operator
* If the Staker has deposit shares in the `EigenPodManager`, the `DelegationManager` adds this shares amount to the Operator's shares for the beacon chain ETH strategy.
* For each of the strategies in the `StrategyManager`, if the Staker holds deposit shares in that strategy they are added to the Operator's shares under the corresponding strategy.
* For each `Strategy` including the beaconChainETHStrategy that increased delegated shares, update the depositScalingFactor for the Staker.

*Requirements*:
* The caller MUST NOT already be delegated to an Operator
* The `operator` MUST already be an Operator
* If the `operator` has a `delegationApprover`, the caller MUST provide a valid `approverSignatureAndExpiry` and `approverSalt`
* Pause status MUST NOT be set: `PAUSED_NEW_DELEGATION`
* `slashingFactor` for the strategy MUST be non-zero

---

### Undelegating and Withdrawing

These methods can be called by both Stakers AND Operators, and are used to (i) undelegate a Staker from an Operator, (ii) queue a withdrawal of a Staker/Operator's shares, or (iii) complete a queued withdrawal:

* [`DelegationManager.undelegate`](#undelegate)
* [`DelegationManager.redelegate`](#redelegate)
* [`DelegationManager.queueWithdrawals`](#queuewithdrawals)
* [`DelegationManager.completeQueuedWithdrawal`](#completequeuedwithdrawal)
* [`DelegationManager.completeQueuedWithdrawals`](#completequeuedwithdrawals)

#### `undelegate`

```solidity
function undelegate(
    address staker
) 
    external 
    onlyWhenNotPaused(PAUSED_ENTER_WITHDRAWAL_QUEUE)
    returns (bytes32[] memory withdrawalRoots)
```

`undelegate` can be called by a Staker to undelegate themselves, or by a Staker's delegated Operator (or that Operator's `delegationApprover`). Undelegation (i) queues withdrawals on behalf of the Staker for all their deposit shares, and (ii) decreases the Operator's delegated shares according to the amounts and strategies being withdrawn.

If the Staker has active deposit shares in either the `EigenPodManager` or `StrategyManager`, they are removed while the withdrawal is in the queue - and an individual withdrawal is queued for each strategy removed.

The withdrawals can be completed by the Staker after `minWithdrawalDelayBlocks()`. This does not require the Staker to "fully exit" from the system -- the Staker may choose to receive their withdrawable shares back in full once withdrawals are completed (see [`completeQueuedWithdrawal`](#completequeuedwithdrawal) for details).

Note that becoming an Operator is irreversible! Although Operators can withdraw, they cannot use this method to undelegate from themselves.

*Effects*: 
* The Staker is undelegated from the Operator
* If the Staker has no deposit shares, there is no withdrawal queued or further effects
* For each strategy being withdrawn, a `Withdrawal` is queued for the Staker even if the Staker and delegated Operator has been 100% fully slashed:
    * Deposit shares for the Staker are converted to withdrawable shares which then is decremented from the Operator's delegated shares.
    * The Staker's withdrawal nonce is increased by 1 for each `Withdrawal`
    * If the Strategy is not beaconChainETHStrategy, `_cumulativeScaledSharesHistory` is updated for the corresponding (Operator, Strategy).
    * The `Withdrawal` is saved to storage
        * The hash of the `Withdrawal` is marked as "pending"
        * The hash of the `Withdrawal` is set in a mapping to the `Withdrawal` struct itself
        * The hash of the `Withdrawal` is pushed to `_stakerQueuedWithdrawalRoots`
* See [`EigenPodManager.removeShares`](./EigenPodManager.md#eigenpodmanagerremoveshares)
* See [`StrategyManager.removeShares`](./StrategyManager.md#removeshares)

*Requirements*:
* Pause status MUST NOT be set: `PAUSED_ENTER_WITHDRAWAL_QUEUE`
* Staker MUST exist and be delegated to someone
* Staker MUST NOT be an Operator
* `staker` parameter MUST NOT be zero
* Caller must be either the Staker, their Operator's permission controlled appointee, or their Operator's `delegationApprover`
* See [`EigenPodManager.removeDepositShares`](./EigenPodManager.md#eigenpodmanagerremovedepositshares)
* See [`StrategyManager.removeDepositShares`](./StrategyManager.md#removedepositshares)

#### `queueWithdrawals`

```solidity
function queueWithdrawals(
    QueuedWithdrawalParams[] calldata queuedWithdrawalParams
) 
    external 
    onlyWhenNotPaused(PAUSED_ENTER_WITHDRAWAL_QUEUE) 
    returns (bytes32[] memory)
```

Allows the caller to queue one or more withdrawals of their held shares across any strategy (in either/both the `EigenPodManager` or `StrategyManager`). If the caller is delegated to an Operator, the `depositShares and `strategies` being withdrawn are calculated to their respective withdrawable shares, which is then immediately removed from that Operator's delegated share balances. Note that if the caller is an Operator, this still applies, as Operators are essentially delegated to themselves.

`queueWithdrawals` works very similarly to `undelegate`, except that the caller is not undelegated, and also may choose which strategies and how many deposit shares to withdraw (as opposed to ALL depositShares/strategies).

All deposit shares being withdrawn (whether via the `EigenPodManager` or `StrategyManager`) are removed while the withdrawals are in the queue.

Withdrawals can be completed by the caller after `minWithdrawalDelayBlocks()`. Withdrawals do not require the caller to "fully exit" from the system -- they may choose to receive their withdrawable shares back in full once the withdrawal is completed (see [`completeQueuedWithdrawal`](#completequeuedwithdrawal) for details). 

Note that the `QueuedWithdrawalParams` struct has a `withdrawer` field. Originally, this was used to specify an address that the withdrawal would be credited to once completed. However, `queueWithdrawals` now requires that `withdrawer == msg.sender`. Any other input is rejected.

*Effects*:
* For each withdrawal:
    * If the caller is delegated to an Operator, deposit shares for the Staker are converted to withdrawable shares which then is decremented from the Operator's delegated shares.
    * The Staker's withdrawal nonce is increased by 1 for each `Withdrawal`
    * If the Strategy is not beaconChainETHStrategy, `_cumulativeScaledSharesHistory` is updated for the corresponding (Operator, Strategy).
    * The `Withdrawal` is saved to storage
        * The hash of the `Withdrawal` is marked as "pending"
        * The hash of the `Withdrawal` is set in a mapping to the `Withdrawal` struct itself
        * The hash of the `Withdrawal` is pushed to `_stakerQueuedWithdrawalRoots`
    * See [`EigenPodManager.removeShares`](./EigenPodManager.md#eigenpodmanagerremoveshares)
    * See [`StrategyManager.removeShares`](./StrategyManager.md#removeshares)

*Requirements*:
* Pause status MUST NOT be set: `PAUSED_ENTER_WITHDRAWAL_QUEUE`
* For each withdrawal:
    * `strategies.length` MUST equal `depositShares.length`
    * The `withdrawer` MUST equal `msg.sender`
    * `strategies.length` MUST NOT be equal to 0
    * `depositSharesToWithdraw` MUST be less than or equal to existing depositShares in `StrategyManager` or `EigenPodManager`
    * See [`EigenPodManager.removeShares`](./EigenPodManager.md#eigenpodmanagerremoveshares)
    * See [`StrategyManager.removeShares`](./StrategyManager.md#removeshares)

#### `completeQueuedWithdrawal`

```solidity
function completeQueuedWithdrawal(
    Withdrawal calldata withdrawal,
    IERC20[] calldata tokens,
    bool receiveAsTokens
) 
    external 
    onlyWhenNotPaused(PAUSED_EXIT_WITHDRAWAL_QUEUE)
    nonReentrant
```

After waiting `minWithdrawalDelayBlocks()` number of blocks, this allows the `withdrawer` of a `Withdrawal` to finalize a withdrawal and receive either (i) the underlying tokens of the strategies being withdrawn from, or (ii) the withdrawable shares being withdrawn. This choice is dependent on the passed-in parameter `receiveAsTokens`.

For each strategy/scaled share pair in the `Withdrawal`:
* The scaled shares in the`Withdrawal` are converted into actual withdrawable shares, accounting for any slashing that has occurred during the withdrawal period.
* If the `withdrawer` chooses to receive tokens:
    * The calculated withdrawable shares are converted to their underlying tokens via either the `EigenPodManager` or `StrategyManager` and sent to the `withdrawer`.
* If the `withdrawer` chooses to receive shares (and the strategy belongs to the `StrategyManager`): 
    * The calculated withdrawable shares are awarded back(redeposited) to the `withdrawer` via the `StrategyManager` as deposit shares.
    * If the `withdrawer` is delegated to an Operator, that Operator's delegated shares are increased by the added deposit shares (according to the strategy being added to).

`Withdrawals` concerning `EigenPodManager` shares have some additional nuance depending on whether a withdrawal is specified to be received as tokens vs shares (read more about "why" in [`EigenPodManager.md`](./EigenPodManager.md)):
* `EigenPodManager` withdrawals received as shares: 
    * OwnedShares ALWAYS go back to the originator of the withdrawal (rather than the `withdrawer` address). 
    * OwnedShares are also delegated to the originator's Operator, rather than the `withdrawer's` Operator.
    * OwnedShares received by the originator may be lower than the shares originally withdrawn if the originator has debt.
* `EigenPodManager` withdrawals received as tokens:
    * Before the withdrawal can be completed, the originator needs to prove that a withdrawal occurred on the beacon chain (see [`EigenPod.verifyAndProcessWithdrawals`](./EigenPodManager.md#eigenpodverifyandprocesswithdrawals)).

*Effects*:
* The hash of the `Withdrawal` is removed from the pending withdrawals
* The hash of the `Withdrawal` is removed from the enumerable set of staker queued withdrawals
* The `Withdrawal` struct is removed from the queued withdrawals 
* If `receiveAsTokens`:
    * See [`StrategyManager.withdrawSharesAsTokens`](./StrategyManager.md#withdrawsharesastokens)
    * See [`EigenPodManager.withdrawSharesAsTokens`](./EigenPodManager.md#eigenpodmanagerwithdrawsharesastokens)
* If `!receiveAsTokens`:
    * For `StrategyManager` strategies:
        * OwnedShares are awarded to the `withdrawer` and delegated to the `withdrawer's` Operator
        * See [`StrategyManager.addShares`](./StrategyManager.md#addshares)
    * For the native beacon chain ETH strategy (`EigenPodManager`):
        * OwnedShares are awarded to `withdrawal.staker`, and delegated to the Staker's Operator
        * See [`EigenPodManager.addShares`](./EigenPodManager.md#eigenpodmanageraddshares)

*Requirements*:
* Pause status MUST NOT be set: `PAUSED_EXIT_WITHDRAWAL_QUEUE`
* `tokens.length` must equal `withdrawal.strategies.length`
* Caller MUST be the `withdrawer` specified in the `Withdrawal`
* At least `minWithdrawalDelayBlocks` MUST have passed before `completeQueuedWithdrawal` is called
* The hash of the passed-in `Withdrawal` MUST correspond to a pending withdrawal
* If `receiveAsTokens`:
    * The caller MUST pass in the underlying `IERC20[] tokens` being withdrawn in the appropriate order according to the strategies in the `Withdrawal`.
    * See [`StrategyManager.withdrawSharesAsTokens`](./StrategyManager.md#withdrawsharesastokens)
    * See [`EigenPodManager.withdrawSharesAsTokens`](./EigenPodManager.md#eigenpodmanagerwithdrawsharesastokens)
* If `!receiveAsTokens`:
    * See [`StrategyManager.addShares`](./StrategyManager.md#addshares)
    * See [`EigenPodManager.addShares`](./EigenPodManager.md#eigenpodmanageraddshares)

#### `completeQueuedWithdrawals`

```solidity
function completeQueuedWithdrawals(
    Withdrawal[] calldata withdrawals,
    IERC20[][] calldata tokens,
    bool[] calldata receiveAsTokens
) 
    external 
    onlyWhenNotPaused(PAUSED_EXIT_WITHDRAWAL_QUEUE) 
    nonReentrant
```

This method is the plural version of [`completeQueuedWithdrawal`](#completequeuedwithdrawal).

---

### Accounting

These methods are called by the `StrategyManager` and `EigenPodManager` to update delegated share accounting when a Staker's balance changes (e.g. due to a deposit):

* [`DelegationManager.increaseDelegatedShares`](#increasedelegatedshares)
* [`DelegationManager.decreaseDelegatedShares`](#decreasedelegatedshares)

#### `increaseDelegatedShares`

```solidity
function increaseDelegatedShares(
    address staker, 
    IStrategy strategy, 
    uint256 shares
)
    external
    onlyStrategyManagerOrEigenPodManager
```

Called by either the `StrategyManager` or `EigenPodManager` when a Staker's shares for one or more strategies increase. This method is called to ensure that if the Staker is delegated to an Operator, that Operator's share count reflects the increase.

*Entry Points*:
* `StrategyManager.depositIntoStrategy`
* `StrategyManager.depositIntoStrategyWithSignature`
* `EigenPod.verifyWithdrawalCredentials`
* `EigenPod.verifyBalanceUpdates`
* `EigenPod.verifyAndProcessWithdrawals`

*Effects*: If the Staker in question is delegated to an Operator, the Operator's shares for the `strategy` are increased.
* This method is a no-op if the Staker is not delegated to an Operator.

*Requirements*:
* Caller MUST be either the `StrategyManager` or `EigenPodManager`

#### `decreaseDelegatedShares`

```solidity
function decreaseDelegatedShares(
    address staker, 
    IStrategy strategy, 
    uint256 shares
)
    external
    onlyStrategyManagerOrEigenPodManager
```

Called by the `EigenPodManager` when a Staker's shares decrease. This method is called to ensure that if the Staker is delegated to an Operator, that Operator's share count reflects the decrease.

*Entry Points*: This method may be called as a result of the following top-level function calls:
* `EigenPod.verifyBalanceUpdates`
* `EigenPod.verifyAndProcessWithdrawals`

*Effects*: If the Staker in question is delegated to an Operator, the Operator's delegated balance for the `strategy` is decreased by `shares`
* This method is a no-op if the Staker is not delegated to an Operator.

*Requirements*:
* Caller MUST be either the `StrategyManager` or `EigenPodManager` (although the `StrategyManager` doesn't use this method)

---

### Slashing

---

### System Configuration

* [`DelegationManager.setMinWithdrawalDelayBlocks`](#setminwithdrawaldelayblocks)
* [`DelegationManager.setStrategyWithdrawalDelayBlocks`](#setstrategywithdrawaldelayblocks)

#### `setMinWithdrawalDelayBlocks`

```solidity
function setMinWithdrawalDelayBlocks(
    uint256 newMinWithdrawalDelayBlocks
) 
    external 
    onlyOwner
```

Allows the Owner to set the overall minimum withdrawal delay for withdrawals concerning any strategy. The total time required for a withdrawal to be completable is at least `minWithdrawalDelayBlocks`. If any of the withdrawal's strategies have a higher per-strategy withdrawal delay, the time required is the maximum of these per-strategy delays.

*Effects*:
* Sets the global `minWithdrawalDelayBlocks`

*Requirements*:
* Caller MUST be the Owner
* The new value MUST NOT be greater than `MAX_WITHDRAWAL_DELAY_BLOCKS`

#### `setStrategyWithdrawalDelayBlocks`

```solidity
function setStrategyWithdrawalDelayBlocks(
    IStrategy[] calldata strategies,
    uint256[] calldata withdrawalDelayBlocks
) 
    external 
    onlyOwner
```

Allows the Owner to set a per-strategy withdrawal delay for each passed-in strategy. The total time required for a withdrawal to be completable is at least `minWithdrawalDelayBlocks`. If any of the withdrawal's strategies have a higher per-strategy withdrawal delay, the time required is the maximum of these per-strategy delays.

*Effects*:
* For each `strategy`, sets `strategyWithdrawalDelayBlocks[strategy]` to a new value

*Requirements*:
* Caller MUST be the Owner
* `strategies.length` MUST be equal to `withdrawalDelayBlocks.length`
* For each entry in `withdrawalDelayBlocks`, the value MUST NOT be greater than `MAX_WITHDRAWAL_DELAY_BLOCKS`