# AllocationManager

| File | Type | Proxy |
| -------- | -------- | -------- |
| [`AllocationManager.sol`](../../src/contracts/core/AllocationManager.sol) | Singleton | Transparent proxy |

## Prerequisites

* [The Mechanics of Allocating and Slashing Unique Stake](https://forum.eigenlayer.xyz/t/the-mechanics-of-allocating-and-slashing-unique-stake/13870)

## Overview

The AllocationManager contract manages the allocation and slashing of operators' slashable stake across various strategies and operator sets. It also enforces allocation and deallocation delays and handles the slashing process initiated by AVSs.

Two types of users interact directly with the AllocationManager:
* [Operators](#operators)
* [AVSs](#avss)

## Parameterization

* `ALLOCATION_CONFIGURATION_DELAY`: The delay in blocks (estimated) before allocations take effect.
    * Mainnet: `126000 blocks` (17.5 days).
    * Testnet: `90 blocks` (15 minutes).
    * Public Devnet: `90 blocks` (15 minutes).
* `DEALLOCATION_DELAY`: The delay in blocks (estimated) before deallocations take effect.
    * Mainnet: `100800 blocks` (14 days).
    * Testnet: `60 blocks` (10 minutes).
    * Public Devnet: `60 blocks` (10 minutes).

## Operators

Operators interact with the AllocationManager to join operator sets, modify their allocations of slashable stake, and change their allocation delay.

### Operator Sets

Operator sets, as described in [Introducing the EigenLayer Security Model](https://www.blog.eigenlayer.xyz/introducing-the-eigenlayer-security-model/), are useful for AVSs to configure operator groupings which can be assigned different tasks, rewarded based on their strategy allocations, and slashed according to different rules.

An operator set is defined as below:

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

Every `OperatorSet` corresponds to a single AVS, as indicated by the `avs` parameter. Each `OperatorSet` is then given a specific `id` upon creation, which must be unique per `avs`. Together, the `avs` and `id` form the `key` that uniquely identifies a given `OperatorSet`.

All members of an operator set are stored in the below mapping:

```solidity
/// @dev Lists the members of an AVS's operator set
    mapping(bytes32 operatorSetKey => EnumerableSet.AddressSet) internal _operatorSetMembers;
```

### Operator Set Registration

The following mapping tracks operator registrations for operator sets:

```solidity
/// @dev Lists the operator sets the operator is registered for. Note that an operator
/// can be registered without allocated stake. Likewise, an operator can allocate
/// without being registered.
mapping(address operator => EnumerableSet.Bytes32Set) internal registeredSets;
```

The `Bytes32Set` value saves a list of `key` values from `OperatorSet` instances. Each operator [registration](#registerforoperatorsets) and [deregistration](#deregisterfromoperatorsets) respectively adds and removes the relevant `key` for a given operator.

The below struct captures the registration status for an operator regarding a given operator set:

```solidity
/**
 * @notice Contains registration details for an operator pertaining to an operator set
 * @param registered Whether the operator is currently registered for the operator set
 * @param registeredUntil If the operator is not registered, how long until the operator is no longer
 * slashable by the AVS.
 */
struct RegistrationStatus {
    bool registered;
    uint32 registeredUntil;
}
```

Note that the `RegistrationStatus` for an operator of an operator set is expected to be in one of three states:
* `registered: false` and `registeredUntil: 0`
  * Before any registrations or deregistrations.
* `registered: true` and `registeredUntil: 0`
  * After an operator has successfully registered for an operator set.
* `registered: false` and `registeredUntil: block.number + DEALLOCATION_DELAY`
  * A deregistered operator. Operators may be slashed for any slashable behavior until the delay has passed.

The below mapping stores that data, where the `operatorSetKey` refers to the `key` described above for a given operator set:

```solidity
/// @dev Contains the operator's registration status for an operator set.
mapping(address operator => mapping(bytes32 operatorSetKey => RegistrationStatus)) internal registrationStatus;
```

#### `registerForOperatorSets`

```solidity
function registerForOperatorSets(
    address operator,
    RegisterParams calldata params
)
external
onlyWhenNotPaused(PAUSED_OPERATOR_SET_REGISTRATION_AND_DEREGISTRATION)
checkCanCall(operator);
```

An operator may call this function to register for any number of operator sets of a given AVS at once. Operator registrations are provided in the form of the struct defined below:

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
```

The `data` is arbitrary information passed onto the AVS's specific `AVSRegistrar` for the AVS's particular considerations for acceptance. If the AVS reverts, registration will fail.

*Effects*:
* Adds the proposed operator sets to the operator's list of registered sets (`registeredSets`)
* Adds the operator to `_operatorSetMembers` for each operator set
* Marks the operator as registered for the given operator sets (in `registrationStatus`)
* Passes the `params` for registration to the AVS's `AVSRegistrar`, which can arbitrarily handle the registration request
* Emits an `OperatorAddedToOperatorSet` event for each operator

*Requirements*:
* Pause status MUST NOT be set: `PAUSED_OPERATOR_SET_REGISTRATION_AND_DEREGISTRATION`
* Address MUST be registered as an operator
* Caller MUST be the operator
  * An admin and/or appointee for the account can also call this function (see the [PermissionController](../permissions/PermissionController.md))
* Each operator set ID MUST exist for the given AVS
* Operator MUST NOT already be registered for any proposed operator sets
* If operator has deregistered, operator MUST NOT be slashable anymore (i.e. the `DEALLOCATION_DELAY` must have passed)
* The AVS's `AVSRegistrar` MUST NOT revert
<!-- There is no explict check that the AVS exists -- presumably captured by checking that the opeartor set ID exists for the AVS? -->

#### `deregisterFromOperatorSets`

```solidity
function deregisterFromOperatorSets(
    DeregisterParams calldata params
)
external
onlyWhenNotPaused(PAUSED_OPERATOR_SET_REGISTRATION_AND_DEREGISTRATION)
```

Operators may desire to deregister from operator sets; this function generally inverts the effects of `registerForOperatorSets` with some specific exceptions.

*Effects*:
* Removes the proposed operator sets from the operator's list of registered sets (`registeredSets`)
* Removes the operator from `_operatorSetMembers` for each operator set
* Marks the operator as deregistered for the given operator sets (in `registrationStatus`)
* Sets the operator's `registeredUntil` value to `uint32(block.number) + DEALLOCATION_DELAY`
  * As mentioned above, this allows for AVSs to slash deregistered operators that performed slashable behavior, until the delay expires
* Emits an `OperatorRemovedFromOperatorSet` event for each operator
* Passes the `params` for registration to the AVS's `AVSRegistrar`, which can arbitrarily handle the deregistration request

*Requirements*:
<!-- * Address MUST be registered as an operator -->
* Pause status MUST NOT be set: `PAUSED_OPERATOR_SET_REGISTRATION_AND_DEREGISTRATION`
* Caller MUST be the operator OR the AVS
  * An admin and/or appointee for either can also call this function (see the [PermissionController](../permissions/PermissionController.md))
* Each operator set ID MUST exist for the given AVS
* Operator MUST be registered for the given operator sets
* Note that, unlike `registerForOperatorSets`, the AVS's `AVSRegistrar` MAY revert and the deregistration will still succeed

### Allocation Modifications

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
  * Updates storage to save any changes stored above in `info` and `allocation`
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
) external;
```

This function is used to complete pending deallocations for a list of strategies for an operator. The function takes a list of strategies and the number of pending deallocations to complete for each strategy. For each strategy, the function completes pending deallocations if their effect timestamps have passed.

Completing a deallocation decreases the encumbered magnitude for the strategy, allowing them to make allocations with that magnitude. Encumbered magnitude must be decreased only upon completion as pending deallocations can be slashed before they are completed.

*Effects*:
* For each `strategies` element, and for each `numToClear` element:
  * Halts if the `numToClear` has been reached (i.e. `numCleared >= numToClear`) or if all deallocations have been cleared
  * Checks if the pending deallocation's effect block has passed, and breaks the loop if not
  * Updates `encumberedMagnitude[operator][strategy]` to the new encumbered magnitude post-deallocation
  * Emits an `EncumberedMagnitudeUpdated` event
  * Removes the now-completed deallocation for the `operatorSet` from `deallocationQueue`
  * Increments `numCleared`
* If the deallocation delay has passed for an allocation, update the allocation information to reflect the successful deallocation, and remove the deallocation from `deallocationQueue`

*Requirements*:
* Pause status MUST NOT be on: `PAUSED_MODIFY_ALLOCATIONS`
* Strategy list MUST be equal length to `numToClear` list

### Allocation Delay Changes

#### `setAllocationDelay`

```solidity
/**
 * @notice Called by operators or the delegation manager to set their allocation delay.
 * @param operator The operator to set the delay on behalf of.
 * @param delay The allocation delay in seconds.
 */
function setAllocationDelay(address operator, uint32 delay) external;
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

## AVSs

### Administrating Operator Sets

#### `createOperatorSets`

```solidity
/**
 * @notice Allows an AVS to create new operator sets, defining strategies that the operator set uses
 */
function createOperatorSets(address avs, CreateSetParams[] calldata params) external;
```

AVSs can make as many operator sets as they desire for their particular purposes.

#### `addStrategiesToOperatorSet`
#### `removeStrategiesFromOperatorSet`
#### `setAVSRegistrar`

### Slashing Operators

#### `slashOperator`

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
    SlashingParams calldata params
) external
```

This function is called by AVSs to slash an operator for a given operator set and list of strategies. The AVS provides the proportion of the operator's slashable stake allocation to slash for each strategy. The proportion is given in parts in 1e18 and is with respect to the operator's _current_ slashable stake allocation for the operator set (i.e. `wadsToSlash=5e17` means 50% of the operator's slashable stake allocation for the operator set will be slashed). The AVS also provides a description of the slashing for legibility by outside integrations.

Slashing is instant and irreversable. Slashed funds remain unrecoverable in the protocol but will be burned/redistributed in a future release. Slashing by one operatorSet does not effect the slashable stake allocation of other operatorSets for the same operator and strategy.

Slashing updates storage in a way that instantly updates all view functions to reflect the correct values.

------

## View Functions

### `getMinDelegatedAndSlashableOperatorSharesBefore`

```solidity
/**
 * @notice returns the minimum operatorShares and the slashableOperatorShares for an operator, list of strategies,
 * and an operatorSet before a given timestamp. This is used to get the shares to weight operators by given ones slashing window.
 * @param operatorSet the operatorSet to get the shares for
 * @param operators the operators to get the shares for
 * @param strategies the strategies to get the shares for
 * @param beforeTimestamp the timestamp to get the shares at
 */
function getMinDelegatedAndSlashableOperatorSharesBefore(
    OperatorSet calldata operatorSet,
    address[] calldata operators,
    IStrategy[] calldata strategies,
    uint32 beforeTimestamp
) external view returns (uint256[][] memory, uint256[][] memory)
```

This function returns the minimum operator shares and the slashable operator shares for an operator, list of strategies, and an operator set before a given timestamp. This is used by AVSs to pessimistically estimate the operator's slashable stake allocation for a given strategy and operator set within their slashability windows. If an AVS calls this function every week and creates tasks that are slashable for a week after they're created, then `beforeTimestamp` should be 2 weeks in the future to account for the latest task that may be created against stale stakes. More on this in new docs soon.

### Additional View Functions

See the [AllocationManager Interface](../../../src/contracts/interfaces/IAllocationManager.sol) for additional view functions.