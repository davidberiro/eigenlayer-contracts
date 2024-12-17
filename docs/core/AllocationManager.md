# AllocationManager

| File | Notes |
| -------- | -------- |
| [`AllocationManager.sol`](../../src/contracts/core/AllocationManager.sol) |  |
| [`AllocationManagerStorage.sol`](../../src/contracts/core/AllocationManagerStorage.sol) | state variables |
| [`IAllocationManager.sol`](../../src/contracts/interfaces/IAllocationManager.sol) | interface |

Libraries and Mixins:

| File | Notes |
| -------- | -------- |
| [`PermissionControllerMixin.sol`](../../src/contracts/mixins/PermissionControllerMixin.sol) | account delegation |
| [`Pausable.sol`](../../src/contracts/permissions/Pausable.sol) | |
| [`SlashingLib.sol`](../../src/contracts/libraries/SlashingLib.sol) | slashing math |
| [`OperatorSetLib.sol`](../../src/contracts/libraries/OperatorSetLib.sol) | encode/decode operator sets |

## Prerequisites

* [The Mechanics of Allocating and Slashing Unique Stake](https://forum.eigenlayer.xyz/t/the-mechanics-of-allocating-and-slashing-unique-stake/13870)

## Overview

The `AllocationManager` manages registration and deregistration of operators to operator sets, handles allocation and slashing of operators' slashable stake, and is the entry point an AVS uses to slash an operator. The `AllocationManager's` responsibilities are broken down into the following concepts:
* [Operator Sets](#operator-sets)
* [Allocations and Slashing](#allocations-and-slashing)
* [Config](#config)

## Parameterization

* `ALLOCATION_CONFIGURATION_DELAY`: The delay in blocks (estimated) before allocations take effect.
    * Mainnet: `126000 blocks` (17.5 days).
    * Testnet: `75 blocks` (15 minutes).
* `DEALLOCATION_DELAY`: The delay in blocks (estimated) before deallocations take effect.
    * Mainnet: `100800 blocks` (14 days).
    * Testnet: `50 blocks` (10 minutes).

---

## Operator Sets

Operator sets, as described in [Introducing the EigenLayer Security Model](https://www.blog.eigenlayer.xyz/introducing-the-eigenlayer-security-model/), are useful for AVSs to configure operator groupings which can be assigned different tasks, rewarded based on their strategy allocations, and slashed according to different rules. Operator sets are defined in [`libraries/OperatorSetLib.sol`](../../src/contracts/libraries/OperatorSetLib.sol):

```solidity
/**
 * @notice An operator set identified by the AVS address and an identifier
 * @param avs The address of the AVS this operator set belongs to
 * @param id The unique identifier for the operator set
 */
struct OperatorSet {
    address avs;
    uint32 id;
}
```

The `AllocationManager` tracks operator sets and members of operator sets in the following mappings:

```solidity
/// @dev Lists the operator set ids an AVS has created
mapping(address avs => EnumerableSet.UintSet) internal _operatorSets;

/// @dev Lists the members of an AVS's operator set
mapping(bytes32 operatorSetKey => EnumerableSet.AddressSet) internal _operatorSetMembers;
```

Every `OperatorSet` corresponds to a single AVS, as indicated by the `avs` parameter. On creation, the AVS provides an `id` (unique to that AVS), as well as a list of `strategies` the `OperatorSet` includes. Together, the `avs` and `id` form the `key` that uniquely identifies a given `OperatorSet`. Operators can register to and deregister from operator sets. In combination with allocating slashable magnitude, operator set registration forms the basis of operator slashability (discussed further in [Allocations and Slashing](#allocations-and-slashing)).

#### Registration Status

Operator registration and deregistration is tracked in the following state variables:

```solidity
/// @dev Lists the operator sets the operator is registered for. Note that an operator
/// can be registered without allocated stake. Likewise, an operator can allocate
/// without being registered.
mapping(address operator => EnumerableSet.Bytes32Set) internal registeredSets;

/**
 * @notice Contains registration details for an operator pertaining to an operator set
 * @param registered Whether the operator is currently registered for the operator set
 * @param slashableUntil If the operator is not registered, they are still slashable until
 * this block is reached.
 */
struct RegistrationStatus {
    bool registered;
    uint32 slashableUntil;
}

/// @dev Contains the operator's registration status for an operator set.
mapping(address operator => mapping(bytes32 operatorSetKey => RegistrationStatus)) internal registrationStatus;
```

For each operator, `registeredSets` keeps a list of `OperatorSet` `keys` for which the operator is currently registered. Each operator registration and deregistration respectively adds and removes the relevant `key` for a given operator. An additional factor in registration is the operator's `RegistrationStatus`.

The `RegistrationStatus.slashableUntil` value is used to ensure an operator remains slashable for a period of time after they initiate deregistration. This is to prevent an operator from committing a slashable offence and immediately deregistering to avoid penalty. This means that when an operator deregisters from an operator set, their `RegistrationStatus.slashableUntil` value is set to `block.number + DEALLOCATION_DELAY`.

**Methods:**
* [`createOperatorSets`](#createoperatorsets)
* [`addStrategiesToOperatorSet`](#addstrategiestooperatorset)
* [`removeStrategiesFromOperatorSet`](#removestrategiesfromoperatorset)
* [`registerForOperatorSets`](#registerforoperatorsets)
* [`deregisterFromOperatorSets`](#deregisterfromoperatorsets)

#### `createOperatorSets`

```solidity
/**
 * @notice Parameters used by an AVS to create new operator sets
 * @param operatorSetId the id of the operator set to create
 * @param strategies the strategies to add as slashable to the operator set
 */
struct CreateSetParams {
    uint32 operatorSetId;
    IStrategy[] strategies;
}

/**
 * @notice Allows an AVS to create new operator sets, defining strategies that the operator set uses
 */
function createOperatorSets(
    address avs,
    CreateSetParams[] calldata params
)
    external
    checkCanCall(avs)
```

_Note: this method can be called directly by an AVS, or by a caller authorized by the AVS via the `PermissionController`. See [`PermissionController.md`](../permissions/PermissionController.md) for details._

AVSs use this method to create new operator sets. An AVS can create as many operator sets as they desire, depending on their needs. Once created, operators can [allocate slashable stake to](#modifyallocations) and [register for](#registerforoperatorsets) these operator sets.

On creation, the `avs` specifies an `operatorSetId` unique to the AVS. Together, the `avs` address and `operatorSetId` create a `key` that uniquely identifies this operator set throughout the `AllocationManager`.

Optionally, the `avs` can provide a list of `strategies`, specifying which strategies will be slashable for the new operator set. AVSs may create operator sets with various strategies based on their needs - and strategies may be added to more than one operator set.

*Effects*:
* For each `CreateSetParams` element:
    * For each `params.strategies` element:
        * Add `strategy` to `_operatorSetStrategies[operatorSetKey]`
        * Emits `StrategyAddedToOperatorSet` event

*Requirements*:
* Caller MUST be authorized, either as the AVS or an admin/appointee (see [`PermissionController.md`](../permissions/PermissionController.md))
* For each `CreateSetParams` element:
    * Each `params.operatorSetId` MUST NOT already exist in `_operatorSets[avs]`
    * Each `params.strategies` array MUST be less than or equal to `MAX_OPERATOR_SET_STRATEGY_LIST_LENGTH`
    
#### `addStrategiesToOperatorSet`

```solidity
/**
 * @notice Allows an AVS to add strategies to an operator set
 * @dev Strategies MUST NOT already exist in the operator set
 * @param avs the avs to set strategies for
 * @param operatorSetId the operator set to add strategies to
 * @param strategies the strategies to add
 */
function addStrategiesToOperatorSet(
    address avs,
    uint32 operatorSetId,
    IStrategy[] calldata strategies
)
    external
    checkCanCall(avs)
```

<!-- TODO: document what happens when an operator allocates and a strategy is added/removed _after_ allocation! (this is expected behavior) -->

_Note: this method can be called directly by an AVS, or by a caller authorized by the AVS via the `PermissionController`. See [`PermissionController.md`](../permissions/PermissionController.md) for details._

This function allows an AVS to add slashable strategies to a given operator set. If any strategy is already registered for the given operator set, the entire call will fail.

*Effects*:
* For each `strategies` element:
    * Adds the strategy to `_operatorSetStrategies[operatorSetKey]`
    * Emits a `StrategyAddedToOperatorSet` event

*Requirements*:
* Caller MUST be authorized, either as the AVS or an admin/appointee (see [`PermissionController.md`](../permissions/PermissionController.md))
* `operatorSetStrategies[operatorSetKey].length() + strategies.length <= MAX_OPERATOR_SET_STRATEGY_LIST_LENGTH`
* The operator set MUST be registered for the AVS
* Each proposed strategy MUST NOT be registered for the operator set

#### `removeStrategiesFromOperatorSet`

```solidity
/**
 * @notice Allows an AVS to remove strategies from an operator set
 * @dev Strategies MUST already exist in the operator set
 * @param avs the avs to remove strategies for
 * @param operatorSetId the operator set to remove strategies from
 * @param strategies the strategies to remove
 */
function removeStrategiesFromOperatorSet(
    address avs,
    uint32 operatorSetId,
    IStrategy[] calldata strategies
)
    external
    checkCanCall(avs)
```

_Note: this method can be called directly by an AVS, or by a caller authorized by the AVS via the `PermissionController`. See [`PermissionController.md`](../permissions/PermissionController.md) for details._

This function allows an AVS to remove slashable strategies from a given operator set. If any strategy is not registered for the given operator set, the entire call will fail.

*Effects*:
* For each `strategies` element:
    * Removes the strategy from `_operatorSetStrategies[operatorSetKey]`
    * Emits a `StrategyRemovedFromOperatorSet` event

*Requirements*:
* Caller MUST be authorized, either as the AVS or an admin/appointee (see [`PermissionController.md`](../permissions/PermissionController.md))
* The operator set MUST be registered for the AVS
* Each proposed strategy MUST be registered for the operator set

#### `registerForOperatorSets`

```solidity
/**
 * @notice Parameters used to register for an AVS's operator sets
 * @param avs the AVS being registered for
 * @param operatorSetIds the operator sets within the AVS to register for
 * @param data extra data to be passed to the AVS to complete registration
 */
struct RegisterParams {
    address avs;
    uint32[] operatorSetIds;
    bytes data;
}

/**
 * @notice Allows an operator to register for one or more operator sets for an AVS. If the operator
 * has any stake allocated to these operator sets, it immediately becomes slashable.
 * @dev After registering within the ALM, this method calls the AVS Registrar's `IAVSRegistrar.
 * registerOperator` method to complete registration. This call MUST succeed in order for 
 * registration to be successful.
 */
function registerForOperatorSets(
    address operator,
    RegisterParams calldata params
)
    external
    onlyWhenNotPaused(PAUSED_OPERATOR_SET_REGISTRATION_AND_DEREGISTRATION)
    checkCanCall(operator)
```

_Note: this method can be called directly by an operator, or by a caller authorized by the operator via the `PermissionController`. See [`PermissionController.md`](../permissions/PermissionController.md) for details._

An operator may call this function to register for any number of operator sets of a given AVS at once. There are two very important details to know about this method:
1. As part of registration, each operator set is added to the operator's `registeredSets`. Note that for each newly-registered set, **any stake allocations to the operator set become immediately slashable**.
2. Once all sets have been added, the AVS's configured `IAVSRegistrar` is called to confirm and complete registration. _This call MUST NOT revert,_ as **AVSs are expected to use this call to reject ineligible operators** (according to their own custom logic). Note that if the AVS has not configured a registrar, the `avs` itself is called.

This method makes an external call to the `IAVSRegistrar.registerOperator` method, passing in the registering `operator`, the `operatorSetIds` being registered for, and the input `params.data` provided during registration. From [`IAVSRegistrar.sol`](../../src/contracts/interfaces/IAVSRegistrar.sol):

```solidity
/**
 * @notice Called by the AllocationManager when an operator wants to register
 * for one or more operator sets. This method should revert if registration
 * is unsuccessful.
 * @param operator the registering operator
 * @param operatorSetIds the list of operator set ids being registered for
 * @param data arbitrary data the operator can provide as part of registration
 */
function registerOperator(address operator, uint32[] calldata operatorSetIds, bytes calldata data) external;
```

*Effects*:
* Adds the proposed operator sets to the operator's list of registered sets (`registeredSets`)
* Adds the operator to `_operatorSetMembers` for each operator set
* Marks the operator as registered for the given operator sets (in `registrationStatus`)
* Passes the `params` for registration to the AVS's `AVSRegistrar`, which can arbitrarily handle the registration request
* Emits an `OperatorAddedToOperatorSet` event for each operator

*Requirements*:
* Pause status MUST NOT be set: `PAUSED_OPERATOR_SET_REGISTRATION_AND_DEREGISTRATION`
* `operator` MUST be registered as an operator in the `DelegationManager`
* Caller MUST be authorized, either the operator themselves, or an admin/appointee (see [`PermissionController.md`](../permissions/PermissionController.md))
* Each `operatorSetId` MUST exist for the given AVS
* Operator MUST NOT already be registered for any proposed operator sets
* If operator has deregistered, operator MUST NOT be slashable anymore (i.e. the `DEALLOCATION_DELAY` must have passed)
* The call to the AVS's configured `IAVSRegistrar` MUST NOT revert

#### `deregisterFromOperatorSets`

```solidity
/**
 * @notice Parameters used to deregister from an AVS's operator sets
 * @param operator the operator being deregistered
 * @param avs the avs being deregistered from
 * @param operatorSetIds the operator sets within the AVS being deregistered from
 */
struct DeregisterParams {
    address operator;
    address avs;
    uint32[] operatorSetIds;
}

/**
 * @notice Allows an operator or AVS to deregister the operator from one or more of the AVS's operator sets.
 * If the operator has any slashable stake allocated to the AVS, it remains slashable until the
 * DEALLOCATION_DELAY has passed.
 * @dev After deregistering within the ALM, this method calls the AVS Registrar's `IAVSRegistrar.
 * deregisterOperator` method to complete deregistration. Unlike when registering, this call MAY FAIL.
 * Failure is permitted to prevent AVSs from being able to maliciously prevent operators from deregistering.
 */
function deregisterFromOperatorSets(
    DeregisterParams calldata params
)
    external
    onlyWhenNotPaused(PAUSED_OPERATOR_SET_REGISTRATION_AND_DEREGISTRATION)
```

_Note: this method can be called directly by an operator/AVS, or by a caller authorized by the operator/AVS via the `PermissionController`. See [`PermissionController.md`](../permissions/PermissionController.md) for details._

This method may be called by EITHER an operator OR an AVS to which an operator is registered; it is intended to allow deregistration to be triggered by EITHER party. This method generally inverts the effects of `registerForOperatorSets`, with two specific exceptions:
1. As part of deregistration, each operator set is removed from the operator's `registeredSets`. HOWEVER, **any stake allocations to that operator set will remain slashable for `DEALLOCATION_DELAY` blocks.**
2. Once all sets have been removed, the AVS's configured `IAVSRegistrar` is called to complete deregistration on the AVS side. **Unlike registration, if this call reverts it will be ignored.** This is to stop an AVS from maliciously preventing operators from deregistering.

This method makes an external call to the `IAVSRegistrar.deregisterOperator` method, passing in the deregistering `operator` and the `operatorSetIds` being deregistered from. From [`IAVSRegistrar.sol`](../../src/contracts/interfaces/IAVSRegistrar.sol):

```solidity
/**
 * @notice Called by the AllocationManager when an operator is deregistered from
 * one or more operator sets. If this method reverts, it is ignored.
 * @param operator the deregistering operator
 * @param operatorSetIds the list of operator set ids being deregistered from
 */
function deregisterOperator(address operator, uint32[] calldata operatorSetIds) external;
```

*Effects*:
* Removes the proposed operator sets from the operator's list of registered sets (`registeredSets`)
* Removes the operator from `_operatorSetMembers` for each operator set
* Updates the operator's `registrationStatus` with:
    * `registered: false`
    * `slashableUntil: block.number + DEALLOCATION_DELAY`
        * As mentioned above, this allows for AVSs to slash deregistered operators until `block.number == slashableUntil`
* Emits an `OperatorRemovedFromOperatorSet` event for each operator
* Passes the `operator` and `operatorSetIds` to the AVS's `AVSRegistrar`, which can arbitrarily handle the deregistration request

*Requirements*:
<!-- * Address MUST be registered as an operator -->
* Pause status MUST NOT be set: `PAUSED_OPERATOR_SET_REGISTRATION_AND_DEREGISTRATION`
* Caller MUST be authorized, either the operator/AVS themselves, or an admin/appointee (see [`PermissionController.md`](../permissions/PermissionController.md))
* Each operator set ID MUST exist for the given AVS
* Operator MUST be registered for the given operator sets
* Note that, unlike `registerForOperatorSets`, the AVS's `AVSRegistrar` MAY revert and the deregistration will still succeed

---

## Allocations and Slashing

Operator registration is one step of preparing to participate in an AVS. Typically, an AVS will also expect operators to allocate slashable stake, such that the AVS has some economic security.

#### `modifyAllocations`

```solidity
/**
 * @notice Modifies the proportions of slashable stake allocated to an operator set from a list of strategies
 * Note that deallocations remain slashable for DEALLOCATION_DELAY blocks therefore when they are cleared they may
 * free up less allocatable magnitude than initially deallocated.
 * @param operator the operator to modify allocations for
 * @param params array of magnitude adjustments for one or more operator sets
 * @dev Updates encumberedMagnitude for the updated strategies
 * @dev msg.sender is used as operator
 */
function modifyAllocations(AllocateParams[] calldata allocations) external onlyWhenNotPaused(PAUSED_MODIFY_ALLOCATIONS)
```

This function is called by operators to adjust the proportions of their slashable stake allocated to different operator sets for different strategies.

Each `(operator, operatorSet, strategy)` tuple can have at most 1 pending modification at a time. The function will revert is there is a pending modification for any of the tuples in the input, where the input is provided within the following struct:

```solidity
/**
 * @notice struct used to modify the allocation of slashable magnitude to an operator set
 * @param operatorSet the operator set to modify the allocation for
 * @param strategies the strategies to modify allocations for
 * @param newMagnitudes the new magnitude to allocate for each strategy to this operator set
 */
struct AllocateParams {
    OperatorSet operatorSet;
    IStrategy[] strategies;
    uint64[] newMagnitudes;
}
```

The total magnitude assigned in pending allocations, active allocations, and pending deallocations for a strategy is known as the **_encumbered magnitude_**. The contract verifies that the encumbered magnitude never exceeds the operator's max magnitude for the strategy. If any allocations cause the encumbered magnitude to exceed the max magnitude, this function reverts.

The function handles two scenarios: _allocations_, and _deallocations_.

_Allocations_ are increases in the proportion of slashable stake allocated to an operator set, and take effect after the operator's `ALLOCATION_DELAY`. The allocation delay must be set for the operator (in `setAllocationDelay()`) before they can call this function.

_Deallocations_ are decreases in the proportion of slashable stake allocated to an operator set, and take effect after the `DEALLOCATION_DELAY`. This enables AVSs enough time to update their view of stakes to the new proportions, expire any tasks created against previous stakes, and conclude any remaining slashes. All deallocations are saved in the following mapping:

```solidity
/// @dev For a strategy, keeps an ordered queue of operator sets that have pending deallocations
/// These must be completed in order to free up magnitude for future allocation
mapping(address operator => mapping(IStrategy strategy => DoubleEndedQueue.Bytes32Deque)) internal deallocationQueue;
```

*Effects*:
* For each `AllocationParam` element:
    * For each `operatorSet` in `deallocationQueue[operator][strategy]`:
        * Checks if the pending deallocation's effect block has passed, and breaks the loop if not
        * Updates `encumberedMagnitude[operator][strategy]` to the new encumbered magnitude post-deallocation
        * Emits an `EncumberedMagnitudeUpdated` event
        * Removes the now-completed deallocation for the `operatorSet` from `deallocationQueue`
    * If the operation is a deallocation:
        * Determines if the operator is considered "slashable", i.e. `true` if: `isRegistered()` is true; the strategy is in the operatorSet; and the allocated magnitude is not 0
            * If slashable:
                * Pushes the `operatorSet` to the back of the `deallocationQueue` for a given `operator` and `strategy`
                * Adds the `DEALLOCATION_DELAY` to the current block number to calculate the block at which the magnitude is no longer slashable (saved in `info.effectBlock`)
            * If not slashable:
                * Removes the magnitude from `info.encumberedMagnitude`
                * Updates `allocation.currentMagnitude` to the new magnitude
                * Sets `allocation.pendingDiff` to 0
    * Else if the operation is an allocation:
        * Adds the magnitude to `info.encumberedMagnitude`
        * Adds the operator's allocation delay to the current block number to calculate the block at which the magnitude is considered slashable (saved in `info.effectBlock`)
    * Calls internal function `_updateAllocationInfo()` to do the following:
        * Updates `encumberedMagnitude` with `info.encumberedMagnitude` given a change, and emits an `EncumberedMagnitudeUpdated` if so
        * If a pending modification remains:
            * Adds `strategy` to `allocatedStrategies` for a given `operator` and `operatorSetKey` if not already present
            * Adds `operatorSetKey` to `allocatedSets` for a given `operator` if not already present
        * Else if the allocated magnitude is now 0:
            * Removes `strategy` from `allocatedStrategies` for a given `operator` and `operatorSetKey`
            * If that was the last `strategy` that the operator has allocated for that given `operatorSetKey`:
                * Removes the `operatorSetKey` from `allocatedSets` for a given operator
    * Emits an `EncumberedMagnitudeUpdated` event
    * Emits an `AllocationUpdated` event

*Requirements*:
* Pause status MUST NOT be set: `PAUSED_MODIFY_ALLOCATIONS`
* Caller MUST be authorized, either as the operator or an admin/appointee (see the [PermissionController](../permissions/PermissionController.md))
* Operator MUST have already set an allocation delay
* For each `AllocationParams` element:
    * Provided strategies MUST be of equal length to provided magnitudes for a given `AllocateParams` object
        * This is to ensure that every strategy has a specified magnitude to allocate
    * Operator set MUST exist for each specified AVS
    * Operator MUST NOT have pending modifications for any given strategy
        * This is enforced after any pending eligible deallocations are cleared
    * New magnitudes MUST NOT match existing ones
    * New encumbered magnitudes MUST NOT exceed max magnitudes for a given `operator`, `operatorSet`, and `strategy`

#### `clearDeallocationQueue`

```solidity
/**
 * @notice This function takes a list of strategies and for each strategy, removes from the deallocationQueue
 * all clearable deallocations up to max `numToClear` number of deallocations, updating the encumberedMagnitude
 * of the operator as needed.
 *
 * @param operator address to clear deallocations for
 * @param strategies a list of strategies to clear deallocations for
 * @param numToClear a list of number of pending deallocations to clear for each strategy
 *
 * @dev can be called permissionlessly by anyone
 */
function clearDeallocationQueue(
    address operator,
    IStrategy[] calldata strategies,
    uint16[] calldata numToComplete
)
    external
```

This function is used to complete pending deallocations for a list of strategies for an operator. The function takes a list of strategies and the number of pending deallocations to complete for each strategy. For each strategy, the function completes pending deallocations if their effect timestamps have passed.

Completing a deallocation decreases the encumbered magnitude for the strategy, allowing them to make allocations with that magnitude. Encumbered magnitude must be decreased only upon completion as pending deallocations can be slashed before they are completed.

*Effects*:
* For each `strategies` element, and for each `numToClear` element:
    * Halts if the `numToClear` has been reached (i.e. `numCleared >= numToClear`) or if all deallocations have been cleared
    * Checks if the pending deallocation's effect block has passed, and breaks the loop if not
    * Calls internal function `_updateAllocationInfo()` to do the following:
        * Updates `encumberedMagnitude` with `info.encumberedMagnitude` given a change, and emits an `EncumberedMagnitudeUpdated` if so
        * If a pending modification remains:
            * Adds `strategy` to `allocatedStrategies` for a given `operator` and `operatorSetKey` if not already present
            * Adds `operatorSetKey` to `allocatedSets` for a given `operator` if not already present
        * Else if the allocated magnitude is now 0:
            * Removes `strategy` from `allocatedStrategies` for a given `operator` and `operatorSetKey`
            * If that was the last `strategy` that the operator has allocated for that given `operatorSetKey`:
                * Removes the `operatorSetKey` from `allocatedSets` for a given operator
    * Removes the now-completed deallocation for the `operatorSet` from `deallocationQueue`
    * Increments `numCleared`
* If the deallocation delay has passed for an allocation, update the allocation information to reflect the successful deallocation, and remove the deallocation from `deallocationQueue`

*Requirements*:
* Pause status MUST NOT be on: `PAUSED_MODIFY_ALLOCATIONS`
* Strategy list MUST be equal length to `numToClear` list

*See [this blog post](https://www.blog.eigenlayer.xyz/introducing-the-eigenlayer-security-model/) for more on the EigenLayer security model.*

AVSs that detect misbehaving operators can slash operators as a punitive action. Slashing operations are proposed in the following format:

```solidity
/**
 * @notice Struct containing parameters to slashing
 * @param operator the address to slash
 * @param operatorSetId the ID of the operatorSet the operator is being slashed on behalf of
 * @param strategies the set of strategies to slash
 * @param wadsToSlash the parts in 1e18 to slash, this will be proportional to the operator's
 * slashable stake allocation for the operatorSet
 * @param description the description of the slashing provided by the AVS for legibility
 */
struct SlashingParams {
    address operator;
    uint32 operatorSetId;
    IStrategy[] strategies;
    uint256[] wadsToSlash;
    string description;
}
```

An AVS specifies the `operator` to slash, the `operatorSet` against which the operator misbehaved, the `strategies` to slash, and proportion of each (represented by `wadsToSlash`). A `description` string allows the AVS to add context to the slash.

#### `slashOperator`

```solidity
/**
 * @notice Called by an AVS to slash an operator for given operatorSetId, list of strategies, and wadToSlash.
 * For each given (operator, operatorSetId, strategy) tuple, bipsToSlash
 * bips of the operatorSet's slashable stake allocation will be slashed
 *
 * @param operator the address to slash
 * @param operatorSetId the ID of the operatorSet the operator is being slashed on behalf of
 * @param strategies the set of strategies to slash
 * @param wadToSlash the parts in 1e18 to slash, this will be proportional to the
 * operator's slashable stake allocation for the operatorSet
 * @param description the description of the slashing provided by the AVS for legibility
 */
function slashOperator(
    address avs,
    SlashingParams calldata params
)
    external
    onlyWhenNotPaused(PAUSED_OPERATOR_SLASHING)
    checkCanCall(avs)
```

This function is called by AVSs to slash an operator for a given operator set and list of strategies. The AVS provides the proportion of the operator's slashable stake allocation to slash for each strategy. The proportion is given in parts in `1e18` and is with respect to the operator's _current_ slashable stake allocation for the operator set (i.e. `wadsToSlash=5e17` means 50% of the operator's slashable stake allocation for the operator set will be slashed). The AVS also provides a description of the slashing for legibility by outside integrations.

Slashing is instant and irreversable. Slashed funds remain unrecoverable in the protocol but will be burned/redistributed in a future release. Slashing by one operatorSet does not effect the slashable stake allocation of other operatorSets for the same operator and strategy.

Slashing updates storage in a way that instantly updates all view functions to reflect the correct values.

Function arguments are provided as follows:

```solidity
/**
 * @notice Struct containing parameters to slashing
 * @param operator the address to slash
 * @param operatorSetId the ID of the operatorSet the operator is being slashed on behalf of
 * @param strategies the set of strategies to slash
 * @param wadsToSlash the parts in 1e18 to slash, this will be proportional to the operator's
 * slashable stake allocation for the operatorSet
 * @param description the description of the slashing provided by the AVS for legibility
 */
struct SlashingParams {
    address operator;
    uint32 operatorSetId;
    IStrategy[] strategies;
    uint256[] wadsToSlash;
    string description;
}
```

Note that a slash is performed on a single operator and operator set at a time, but can take in any number of `strategies`. All of these strategies must be registered to the operator set.

*Effects*:
* For each `params.strategies` element:
    * Calculates magnitude to slash by multiplying current magnitude by the provided `wadsToSlash` for the given strategy, and subtracts this value from `allocation.currentMagnitude`, `info.maxMagnitude`, and `info.encumberedMagnitude`
    * If there is a pending deallocation:
        * Reduces `allocation.pendingDiff` proportional to `wadsToSlash` for the given strategy
        * Emits an `AllocationUpdated` event
    * Calls internal function `_updateAllocationInfo()` to do the following:
        * Updates `encumberedMagnitude` with `info.encumberedMagnitude` given a change, and emits an `EncumberedMagnitudeUpdated` if so
        * If a pending modification remains:
            * Adds `strategy` to `allocatedStrategies` for a given `operator` and `operatorSetKey` if not already present
            * Adds `operatorSetKey` to `allocatedSets` for a given `operator` if not already present
        * Else if the allocated magnitude is now 0:
            * Removes `strategy` from `allocatedStrategies` for a given `operator` and `operatorSetKey`
            * If that was the last `strategy` that the operator has allocated for that given `operatorSetKey`:
                * Removes the `operatorSetKey` from `allocatedSets` for a given operator
    * Emits an `AllocationUpdated` event
    * Pushes a new entry to `_maxMagnitudeHistory` for a given `operator` and `strategy` with the current block number and new max magnitude
    * Emits a `MaxMagnitudeUpdated` event
    * Calls [`DelegationManager`](./DelegationManager.md) function `burnOperatorShares()`
* Emits an `OperatorSlashed` event

*Requirements*:
* Pause status MUST NOT be set: `PAUSED_OPERATOR_SLASHING`
* Caller MUST be authorized, either as the AVS or an admin/appointee (see the [PermissionController](../permissions/PermissionController.md))
* Operator set MUST be registered for the AVS
* Operator MUST BE slashable, i.e.:
    * Operator is registreed for the operator set, *OR*
    * The operator's `DEALLOCATION_DELAY` has not yet completed
* `params.strategies` MUST be in ascending order (to ensure no duplicates)
* For each `params.strategies` element:
    * `0` MUST BE less than `wadsToSlash` which MUST BE less than `1e18`
    * Operator set MUST contain the strategy
    * Operator SHOULD have allocated magnitude > 0 to the operator set for this strategy, else `continue`

---

## Config

#### `setAllocationDelay`

```solidity
/**
 * @notice Called by operators or the delegation manager to set their allocation delay.
 * @param operator The operator to set the delay on behalf of.
 * @param delay The allocation delay in seconds.
 */
function setAllocationDelay(
    address operator,
    uint32 delay
)
    external
```

This function sets an operator's allocation delay.

The DelegationManager calls this upon operator registration for all new operators created after the slashing release. Operators can also update their allocation delay, or set it for the first time if they joined before the slashing release.

The allocation delay takes effect in `ALLOCATION_CONFIGURATION_DELAY` blocks.

The allocation delay can be any `uint32`, including 0.

The allocation delay's primary purpose is to give stakers delegated to an operator the chance to withdraw their stake before the operator can change the risk profile to something they're not comfortable with.

This function must be called before allocating stake via `modifyAllocations()`.

*Effects*:
* Sets the operator's `pendingDelay` to the proposed `delay`, and save the `effectBlock` at which the `pendingDelay` can be activated
    * `effectBlock = uint32(block.number) + ALLOCATION_CONFIGURATION_DELAY`
* If the operator has a `pendingDelay`, and if the `effectBlock` has passed, sets the operator's `delay` to the `pendingDelay` value
    * This also sets the `isSet` boolean to `true` to indicate that the operator's `delay`, even if 0, was set intentionally
* Emits an `AllocationDelaySet` event

*Requirements*:
* Caller MUST BE either the DelegationManager, or a registered operator
    * An admin and/or appointee for the operator can also call this function (see the [PermissionController](../permissions/PermissionController.md))

#### `setAVSRegistrar`

```solidity
function setAVSRegistrar(
    address avs,
    IAVSRegistrar registrar
)
    external
    checkCanCall(avs)
```

Sets the `registrar` for a given `avs`. Note that if the registrar is set to 0, `getAVSRegistrar` will return the AVS's address.

The `avs => registrar` mapping is saved in the mapping below:

```solidity
/// @dev Contains the AVS's configured registrar contract that handles registration/deregistration
/// Note: if set to 0, defaults to the AVS's address
mapping(address avs => IAVSRegistrar) internal _avsRegistrar;
```

*Effects*:
* Sets `_avsRegistrar[avs]` to `registrar`
* Emits an `AVSRegistrarSet` event

*Requirements*:
* None