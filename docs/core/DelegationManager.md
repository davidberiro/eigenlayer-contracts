## DelegationManager

| File | Notes |
| -------- | -------- |
| [`DelegationManager.sol`](../../src/contracts/core/DelegationManager.sol) | |
| [`DelegationManagerStorage.sol`](../../src/contracts/core/DelegationManagerStorage.sol) | state variables |
| [`IDelegationManager.sol`](../../src/contracts/interfaces/IDelegationManager.sol) | interface |

Libraries and Mixins:

| File | Notes |
| -------- | -------- |
| [`PermissionControllerMixin.sol`](../../src/contracts/mixins/PermissionControllerMixin.sol) | account delegation |
| [`SignatureUtils.sol`](../../src/contracts/mixins/SignatureUtils.sol) | signature validation |
| [`Pausable.sol`](../../src/contracts/permissions/Pausable.sol) | |
| [`SlashingLib.sol`](../../src/contracts/libraries/SlashingLib.sol) | slashing math |
| [`Snapshots.sol`](../../src/contracts/libraries/Snapshots.sol) | historical state |

## Prior Reading

* [ELIP-002: Slashing via Unique Stake and Operator Sets](https://github.com/eigenfoundation/ELIPs/blob/main/ELIPs/ELIP-002.md)
* [Shares Accounting](./accounting/SharesAccounting.md)

## Overview

The `DelegationManager` is the intersection between the two sides of the protocol. It (i) allows Stakers to delegate/undelegate to/from Operators, (ii) handles withdrawals and withdrawal processing for assets in both the `StrategyManager` and `EigenPodManager`, and (iii) manages accounting around slashing for Stakers and Operators.

When Operators are slashed by AVSs, it receives share burning directives from the `AllocationManager`. When Stakers deposit assets using the `StrategyManager/EigenPodManager`, it tracks share/delegation accounting changes. The `DelegationManager` combines inputs from both sides of the protocol into a Staker's "deposit scaling factor," which serves as the primary conversion vehicle between a Staker's _raw deposited assets_ and the _amount they can withdraw_.

The `DelegationManager's` responsibilities can be broken down into the following concepts:
* [Becoming an Operator](#becoming-an-operator)
* [Delegation and Withdrawals](#delegation-and-withdrawals)
* [Slashing and Accounting](#slashing-and-accounting)

## Parameterization

* `MIN_WITHDRAWAL_DELAY_BLOCKS`: The delay in blocks before withdrawals can be completed.
    * Mainnet: `100800 blocks` (14 days).
    * Testnet: `50 blocks` (10 minutes).
* `beaconChainETHStrategy`: a pseudo strategy used to represent beacon chain ETH internally. This is not a real contract!
    * Value: `0xbeaC0eeEeeeeEEeEeEEEEeeEEeEeeeEeeEEBEaC0`

---

## Becoming an Operator

The `DelegationManager` tracks operator-related state in the following mappings:

```solidity
/// @notice Returns the `operator` a `staker` is delgated to, or address(0) if not delegated.
/// Note: operators are delegated to themselves
mapping(address staker => address operator) public delegatedTo;

/// @notice Returns the operator details for a given `operator`.
/// Note: two of the `OperatorDetails` fields are deprecated. The only relevant field
/// is `OperatorDetails.delegationApprover`.
mapping(address operator => OperatorDetails) internal _operatorDetails;

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
```

**Methods**:
* [`DelegationManager.registerAsOperator`](#registerasoperator)
* [`DelegationManager.modifyOperatorDetails`](#modifyoperatordetails)
* [`DelegationManager.updateOperatorMetadataURI`](#updateoperatormetadatauri)

#### `registerAsOperator`

```solidity
/**
 * @notice Registers the caller as an operator in EigenLayer.
 * @param initDelegationApprover is an address that, if set, must provide a signature when stakers delegate
 * to an operator.
 * @param allocationDelay The delay before allocations take effect.
 * @param metadataURI is a URI for the operator's metadata, i.e. a link providing more details on the operator.
 *
 * @dev Once an operator is registered, they cannot 'deregister' as an operator, and they will forever be considered "delegated to themself".
 * @dev This function will revert if the caller is already delegated to an operator.
 * @dev Note that the `metadataURI` is *never stored * and is only emitted in the `OperatorMetadataURIUpdated` event
 */
function registerAsOperator(
    address initDelegationApprover,
    uint32 allocationDelay,
    string calldata metadataURI
) external;
```

Registers the caller as an Operator in EigenLayer. The new Operator provides the following input parameters:
* `address initDelegationApprover`: *(OPTIONAL)* if set to a non-zero address, this address must sign and approve new delegation from Stakers to this Operator (See [`delegateTo`](#delegateto))
* `uint32 allocationDelay`: the delay (in blocks) before slashable stake allocations will take effect. This is passed to the `AllocationManager` (See [`AllocationManager.md#setAllocationDelay`](./AllocationManager.md#setallocationdelay))
* `string calldata metadataURI`: emits this input in the event `OperatorMetadataURIUpdated`. Does not store the value anywhere.

`registerAsOperator` cements the Operator's delegation approver and allocation delay in storage, and self-delegates the Operator to themselves - permanently marking the caller as an Operator. They cannot "deregister" as an Operator - however, if they have deposited funds, they can still withdraw them (See [Delegation and Withdrawals](#delegation-and-withdrawals)).

*Effects*:
* Sets `_operatorDetails[operator].delegationApprover`. Note that the other `OperatorDetails` fields are deprecated; only the `delegationApprover` is used.
* Delegates the Operator to themselves
    * Tabulates any deposited shares across the `EigenPodManager` and `StrategyManager`, and delegates these shares to themselves
    * For each strategy in which the Operator holds assets, updates the Operator's `depositScalingFactor` for that strategy

*Requirements*:
* Caller MUST NOT already be delegated
* Pause status MUST NOT be set: `PAUSED_NEW_DELEGATION`
* For each strategy in which the Operator holds assets, their `slashingFactor` for that strategy MUST be non-zero.

#### `modifyOperatorDetails`

```solidity
/**
 * @notice Updates an operator's stored `delegationApprover`.
 * @param operator is the operator to update the delegationApprover for
 * @param newDelegationApprover is the new delegationApprover for the operator
 *
 * @dev The caller must have previously registered as an operator in EigenLayer.
 */
function modifyOperatorDetails(
    address operator, 
    address newDelegationApprover
) 
    external 
    checkCanCall(operator)
```

_Note: this method can be called directly by an operator, or by a caller authorized by the operator. See [`PermissionController.md`](../permissions/PermissionController.md) for details._

Allows an Operator to update their stored `delegationApprover`.

*Requirements*:
* `address operator` MUST already be an Operator.
* Caller MUST be authorized: either the operator themselves, or an admin/appointee (see [`PermissionController.md`](../permissions/PermissionController.md))

#### `updateOperatorMetadataURI`

```solidity
/**
 * @notice Called by an operator to emit an `OperatorMetadataURIUpdated` event indicating the information has updated.
 * @param operator The operator to update metadata for
 * @param metadataURI The URI for metadata associated with an operator
 * @dev Note that the `metadataURI` is *never stored * and is only emitted in the `OperatorMetadataURIUpdated` event
 */
function updateOperatorMetadataURI(
    address operator, 
    string calldata metadataURI
) 
    external 
    checkCanCall(operator)
```

_Note: this method can be called directly by an operator, or by a caller authorized by the operator. See [`PermissionController.md`](../permissions/PermissionController.md) for details._

Allows an Operator to emit an `OperatorMetadataURIUpdated` event. No other state changes occur.

*Requirements*:
* `address operator` MUST already be an Operator.
* Caller MUST be authorized: either the operator themselves, or an admin/appointee (see [`PermissionController.md`](../permissions/PermissionController.md))

---

## Delegation and Withdrawals

**Concepts**:
* [Enforcing a Withdrawal Delay]() TODO
* [Legacy vs New Withdrawals]() TODO
* [Getting the Slashing Factor]() TODO

**Methods**:
* [`DelegationManager.delegateTo`](#delegateto)
* [`DelegationManager.undelegate`](#undelegate)
* [`DelegationManager.redelegate`](#redelegate)
* [`DelegationManager.queueWithdrawals`](#queuewithdrawals)
* [`DelegationManager.completeQueuedWithdrawal`](#completequeuedwithdrawal)
* [`DelegationManager.completeQueuedWithdrawals`](#completequeuedwithdrawals)

<!-- TODO - explicitly document beacon chain slashing factor edgecase here or in the EPM -->

#### Role of the Withdrawal Delay

TODO

#### Legacy and Post-Slashing Withdrawals

The `DelegationManager` tracks withdrawal-related state in the following mappings:

```solidity
/// @dev Returns whether a withdrawal is pending for a given `withdrawalRoot`.
/// @dev This variable will be deprecated in the future, values should only be read or deleted.
mapping(bytes32 withdrawalRoot => bool pending) public pendingWithdrawals;

/// @notice Returns the total number of withdrawals that have been queued for a given `staker`.
/// @dev This only increments (doesn't decrement), and is used to help ensure that otherwise identical withdrawals have unique hashes.
mapping(address staker => uint256 totalQueued) public cumulativeWithdrawalsQueued;

/// @notice Returns a list of queued withdrawals for a given `staker`.
/// @dev Entries are removed when the withdrawal is completed.
/// @dev This variable only reflects withdrawals that were made after the slashing release.
mapping(address staker => EnumerableSet.Bytes32Set withdrawalRoots) internal _stakerQueuedWithdrawalRoots;

/// @notice Returns the details of a queued withdrawal given by `withdrawalRoot`.
/// @dev This variable only reflects withdrawals that were made after the slashing release.
mapping(bytes32 withdrawalRoot => Withdrawal withdrawal) public queuedWithdrawals;

/// @notice Contains history of the total cumulative staker withdrawals for an operator and a given strategy.
/// Used to calculate burned StrategyManager shares when an operator is slashed.
/// @dev Stores scaledShares instead of total withdrawn shares to track current slashable shares, dependent on the maxMagnitude
mapping(address operator => mapping(IStrategy strategy => Snapshots.DefaultZeroHistory)) internal
    _cumulativeScaledSharesHistory;
```

Of these mappings, only `pendingWithdrawals` and `cumulativeWithdrawalsQueued`

#### Slashing Factors and Scaling Shares

Throughout the `DelegationManager`, the conversion of a staker's _deposit shares_ into _withdrawable shares_ involves

```solidity


/// @notice Returns the scaling factor applied to a `staker` for a given `strategy`
mapping(address staker => mapping(IStrategy strategy => DepositScalingFactor)) internal _depositScalingFactor;
```

#### `delegateTo`

```solidity
// @notice Struct that bundles together a signature and an expiration time for the signature. Used primarily for stack management.
struct SignatureWithExpiry {
    // the signature itself, formatted as a single bytes object
    bytes signature;
    // the expiration timestamp (UTC) of the signature
    uint256 expiry;
}

/**
 * @notice Caller delegates their stake to an operator.
 * @param operator The account (`msg.sender`) is delegating its assets to for use in serving applications built on EigenLayer.
 * @param approverSignatureAndExpiry (optional) Verifies the operator approves of this delegation
 * @param approverSalt (optional) A unique single use value tied to an individual signature.
 * @dev The signature/salt are used ONLY if the operator has configured a delegationApprover.
 * If they have not, these params can be left empty.
 */
function delegateTo(
    address operator, 
    SignatureWithExpiry memory approverSignatureAndExpiry, 
    bytes32 approverSalt
) 
    external
```

Allows a Staker to delegate their assets to an Operator. Delegation is all-or-nothing: when a Staker delegates to an Operator, they delegate ALL their assets. For each strategy the Staker has deposit shares in, the `DelegationManager` will:
* Query the staker's deposit shares from the `StrategyManager/EigenPodManager`
* Get the slashing factor to apply for this `(staker, operator, strategy)` (See TODO concept above)
* Add the deposit shares to the operator's `operatorShares` directly. _Note_ that the initial delegation to an operator is a special case where deposit shares == withdrawable shares.

update the Operator's corresponding delegated share amounts.

*Effects*:
* Delegates the caller to the `operator`
    * Tabulates any deposited shares across the `EigenPodManager` and `StrategyManager`, and delegates these shares to the `operator`
    * For each strategy in which the caller holds assets, updates the caller's `depositScalingFactor` for that strategy

*Requirements*:
* The caller MUST NOT already be delegated to an Operator
* The `operator` MUST already be an Operator
* If the `operator` has a `delegationApprover`, the caller MUST provide a valid `approverSignatureAndExpiry` and `approverSalt`
* Pause status MUST NOT be set: `PAUSED_NEW_DELEGATION`
* For each strategy in which the staker holds assets, the `slashingFactor` for that strategy MUST be non-zero.

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

## Slashing and Accounting

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