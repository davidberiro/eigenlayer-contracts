// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.5.0;

import "./IDelegationManager.sol";
import "./ISignatureUtils.sol";

interface IAVSDirectory is ISignatureUtils {
    /// @notice Enum representing the registration status of an operator with an AVS.
    /// @notice Only used by legacy M2 AVSs that have not integrated with operatorSets.
    enum OperatorAVSRegistrationStatus {
        UNREGISTERED, // Operator not registered to AVS
        REGISTERED // Operator registered to AVS

    }

    /**
     * @notice Struct representing the registration status of an operator with an operator set.
     * Keeps track of last deregistered timestamp for slashability concerns.
     * @param registered whether the operator is registered with the operator set
     * @param lastDeregisteredTimestamp the timestamp at which the operator was last deregistered
     */
    struct OperatorSetRegistrationStatus {
        bool registered;
        uint32 lastDeregisteredTimestamp;
    }

    /// @notice Struct representing an operator set
    struct OperatorSet {
        address avs;
        uint32 operatorSetId;
    }

    /**
     * @notice this struct is used in allocate and queueDeallocation in order to specify an operator's slashability for a certain operator set
     *
     * @param strategy the strategy to adjust slashable stake for
     * @param operatorSets the operator sets to adjust slashable stake for
     * @param magnitudeDiff magnitude difference; the difference in proportional parts of the operator's slashable stake
     * that is slashable by the operatorSet.
     * Slashable stake for an operator set is (magnitude / totalMagnitude) of an operator's delegated stake.
     */
    struct MagnitudeAdjustment {
        IStrategy strategy;
        OperatorSet[] operatorSets;
        uint64[] magnitudeDiffs;
    }

    /**
     * @notice struct used for queued deallocations. Stored in (operator, strategy, operatorSet) mapping
     * to be used in completeDeallocations.
     * @param magnitudeDiff the amount of magnitude to deallocate
     * @param completableTimestamp the timestamp at which the deallocation can be completed, 21 days from when queued
     */
    struct QueuedDeallocation {
        uint64 magnitudeDiff;
        uint32 completableTimestamp;
    }

    /// @notice Emitted when an operator set is created by an AVS.
    event OperatorSetCreated(OperatorSet operatorSet);

    /**
     *  @notice Emitted when an operator's registration status with an AVS id udpated
     *  @notice Only used by legacy M2 AVSs that have not integrated with operatorSets.
     */
    event OperatorAVSRegistrationStatusUpdated(
        address indexed operator, address indexed avs, OperatorAVSRegistrationStatus status
    );

    /// @notice Emitted when an operator is added to an operator set.
    event OperatorAddedToOperatorSet(address indexed operator, OperatorSet operatorSet);

    /// @notice Emitted when an operator is removed from an operator set.
    event OperatorRemovedFromOperatorSet(address indexed operator, OperatorSet operatorSet);

    /// @notice Emitted when an AVS updates their metadata URI (Uniform Resource Identifier).
    /// @dev The URI is never stored; it is simply emitted through an event for off-chain indexing.
    event AVSMetadataURIUpdated(address indexed avs, string metadataURI);

    /// @notice Emitted when an AVS migrates to using operator sets.
    event AVSMigratedToOperatorSets(address indexed avs);

    /// @notice Emitted when an operator is migrated from M2 registration to operator sets.
    event OperatorMigratedToOperatorSets(address indexed operator, address indexed avs, uint32[] operatorSetIds);

    /// @notice Emitted when an operator allocates slashable magnitude to an operator set
    event MagnitudeAllocated(
        address operator,
        IStrategy strategy,
        OperatorSet operatorSet,
        uint64 magnitudeToAllocate,
        uint32 effectTimestamp
    );

    /// @notice Emitted when an operator queues deallocations of slashable magnitude from an operator set
    event MagnitudeQueueDeallocated(
        address operator,
        IStrategy strategy,
        OperatorSet operatorSet,
        uint64 magnitudeToDeallocate,
        uint32 completableTimestamp
    );

    /// @notice Emitted when an operator completes deallocations of slashable magnitude from an operator set
    /// and adds back magnitude to free allocatable magnitude
    event MagnitudeDeallocationCompleted(
        address operator,
        IStrategy strategy,
        OperatorSet operatorSet,
        uint64 freeMagnitudeAdded
    );

    /// @notice Emitted when an operator is slashed by an operator set for a strategy
    event OperatorSlashed(
        address operator,
        uint32 operatorSetId,
        IStrategy strategy,
        uint16 bipsToSlash
    );

    /**
     *
     *                         EXTERNAL FUNCTIONS
     *
     */

    /**
     * @notice Called by an AVS to create a list of new operatorSets.
     *
     * @param operatorSetIds The IDs of the operator set to initialize.
     *
     * @dev msg.sender must be the AVS.
     * @dev The AVS may create operator sets before it becomes an operator set AVS.
     */
    function createOperatorSets(uint32[] calldata operatorSetIds) external;

    /**
     * @notice Sets the AVS as an operator set AVS, preventing legacy M2 operator registrations.
     *
     * @dev msg.sender must be the AVS.
     */
    function becomeOperatorSetAVS() external;

    /**
     * @notice Called by an AVS to migrate operators that have a legacy M2 registration to operator sets.
     *
     * @param operators The list of operators to migrate
     * @param operatorSetIds The list of operatorSets to migrate the operators to
     *
     * @dev The msg.sender used is the AVS
     * @dev The operator can only be migrated at most once per AVS
     * @dev The AVS can no longer register operators via the legacy M2 registration path once it begins migration
     * @dev The operator is deregistered from the M2 legacy AVS once migrated
     */
    function migrateOperatorsToOperatorSets(
        address[] calldata operators,
        uint32[][] calldata operatorSetIds
    ) external;

    /**
     *  @notice Called by AVSs to add an operator to list of operatorSets.
     *
     *  @param operator The address of the operator to be added to the operator set.
     *  @param operatorSetIds The IDs of the operator sets.
     *  @param operatorSignature The signature of the operator on their intent to register.
     *
     *  @dev msg.sender is used as the AVS.
     *  @dev The operator must not have a pending deregistration from the operator set.
     */
    function registerOperatorToOperatorSets(
        address operator,
        uint32[] calldata operatorSetIds,
        ISignatureUtils.SignatureWithSaltAndExpiry memory operatorSignature
    ) external;

    /**
     *  @notice Called by AVSs to remove an operator from an operator set.
     *
     *  @param operator The address of the operator to be removed from the operator set.
     *  @param operatorSetIds The IDs of the operator sets.
     *
     *  @dev msg.sender is used as the AVS.
     */
    function deregisterOperatorFromOperatorSets(address operator, uint32[] calldata operatorSetIds) external;

    /**
     * @notice Called by an operator to deregister from an operator set
     *
     * @param operator The operator to deregister from the operatorSets.
     * @param avs The address of the AVS to deregister the operator from.
     * @param operatorSetIds The IDs of the operator sets.
     * @param operatorSignature the signature of the operator on their intent to deregister or empty if the operator itself is calling
     *
     * @dev if the operatorSignature is empty, the caller must be the operator
     * @dev this will likely only be called in case the AVS contracts are in a state that prevents operators from deregistering
     */
    function forceDeregisterFromOperatorSets(
        address operator,
        address avs,
        uint32[] calldata operatorSetIds,
        ISignatureUtils.SignatureWithSaltAndExpiry memory operatorSignature
    ) external;

    /**
     * @notice Allocates a set of magnitude adjustments to increase the slashable stake of an operator set for the given operator for the given strategy.
     * Nonslashable magnitude for each strategy will decrement by the sum of all 
     * allocations for that strategy and the allocations will take effect 21 days from calling.
     *
     * @param operator address to increase allocations for
     * @param allocations array of magnitude adjustments for multiple strategies and corresponding operator sets
     * @param operatorSignature signature of the operator if msg.sender is not the operator
     */
    function allocate(
        address operator,
        MagnitudeAdjustment[] calldata allocations,
        SignatureWithSaltAndExpiry calldata operatorSignature
    ) external;

    /**
     * @notice Queues a set of magnitude adjustments to decrease the slashable stake of an operator set for the given operator for the given strategy.
     * The deallocations will take effect 21 days from calling. In order for the operator to have their nonslashable magnitude increased, 
     * they must call the contract again to complete the deallocation. Stake deallocations are still subject to slashing until 21 days have passed since queuing.
     *
     * @param operator address to decrease allocations for
     * @param deallocations array of magnitude adjustments for multiple strategies and corresponding operator sets
     * @param operatorSignature signature of the operator if msg.sender is not the operator
     */
    function queueDeallocate(
        address operator,
        MagnitudeAdjustment[] calldata deallocations,
        SignatureWithSaltAndExpiry calldata operatorSignature
    ) external;

    /**
     * @notice Complete queued deallocations of slashable stake for an operator, permissionlessly called by anyone
     * Increments the free magnitude of the operator by the sum of all deallocation amounts for each strategy. 
     * If the operator was slashed, this will be a smaller amount than during queuing.
     *
     * @param operator address to complete deallocations for
     * @param strategies a list of strategies to complete deallocations for
     * @param operatorSets a 2d list of operator sets to complete deallocations for, one list for each strategy
     *
     * @dev can be called permissionlessly by anyone
     */
    function completeDeallocations(
        address operator,
        IStrategy[] calldata strategies,
        OperatorSet[][] calldata operatorSets
    ) external;

    /**
     * @notice Called by an AVS to slash an operator for given operatorSetId, list of strategies, and bipsToSlash.
     * For each given (operator, operatorSetId, strategy) tuple, bipsToSlash
     * bips of the operatorSet's slashable stake allocation will be slashed
     *
     * @param operator the address to slash
     * @param operatorSetId the ID of the operatorSet the operator is being slashed on behalf of
     * @param strategies the set of strategies to slash
     * @param bipsToSlash the number of bips to slash, this will be proportional to the
     * operator's slashable stake allocation for the operatorSet
     */
    function slashOperator(
        address operator,
        uint32 operatorSetId,
        IStrategy[] calldata strategies,
        uint16 bipsToSlash
    ) external;

    /**
     *  @notice Called by an AVS to emit an `AVSMetadataURIUpdated` event indicating the information has updated.
     *
     *  @param metadataURI The URI for metadata associated with an AVS.
     *
     *  @dev Note that the `metadataURI` is *never stored* and is only emitted in the `AVSMetadataURIUpdated` event.
     */
    function updateAVSMetadataURI(string calldata metadataURI) external;

    /**
     * @notice Called by an operator to cancel a salt that has been used to register with an AVS.
     *
     * @param salt A unique and single use value associated with the approver signature.
     */
    function cancelSalt(bytes32 salt) external;

    /**
     *
     *                         VIEW FUNCTIONS
     *
     */

    /**
     * @notice operator is slashable by operatorSet if currently registered OR last deregistered within 21 days
     * @param operator the operator to check slashability for
     * @param operatorSet the operatorSet to check slashability for
     * @return bool if the operator is slashable by the operatorSet
     */
    function isOperatorSlashable(address operator, OperatorSet memory operatorSet) external view returns (bool);

    /**
     * @param operator the operator to get the slashable bips for
     * @param operatorSet the operatorSet to get the slashable bips for
     * @param strategy the strategy to get the slashable bips for
     * @param timestamp the timestamp to get the slashable bips for for
     *
     * @return slashableBips the slashable bips of the given strategy owned by
     * the given OperatorSet for the given operator and timestamp
     */
    function getSlashableBips(
        address operator,
        OperatorSet calldata operatorSet,
        IStrategy strategy,
        uint32 timestamp
    ) external view returns (uint16);
    
    function operatorSaltIsSpent(address operator, bytes32 salt) external view returns (bool);

    function isMember(address operator, OperatorSet memory operatorSet) external view returns (bool);

    function isOperatorSetAVS(address avs) external view returns (bool);

    function isOperatorSet(address avs, uint32 operatorSetId) external view returns (bool);

    /**
     * @notice Returns operator set an operator is registered to in the order they were registered.
     * @param operator The operator address to query.
     * @param index The index of the enumerated list of operator sets.
     */
    function operatorSetsMemberOfAtIndex(address operator, uint256 index) external view returns (OperatorSet memory);

    /**
     * @notice Retursn the operator registered to an operatorSet in the order that it was registered.
     *  @param operatorSet The operatorSet to query.
     *  @param index The index of the enumerated list of operators.
     */
    function operatorSetMemberAtIndex(OperatorSet memory operatorSet, uint256 index) external view returns (address);

    /**
     * @notice Returns an array of operator sets an operator is registered to.
     * @param operator The operator address to query.
     * @param start The starting index of the array to query.
     *  @param length The amount of items of the array to return.
     */
    function getOperatorSetsOfOperator(
        address operator,
        uint256 start,
        uint256 length
    ) external view returns (OperatorSet[] memory operatorSets);

    /**
     * @notice Returns an array of operators registered to the operatorSet.
     * @param operatorSet The operatorSet to query.
     * @param start The starting index of the array to query.
     * @param length The amount of items of the array to return.
     */
    function getOperatorsInOperatorSet(
        OperatorSet memory operatorSet,
        uint256 start,
        uint256 length
    ) external view returns (address[] memory operators);

    /**
     * @notice Returns the number of operators registered to an operatorSet.
     * @param operatorSet The operatorSet to get the member count for
     */
    function getNumOperatorsInOperatorSet(OperatorSet memory operatorSet) external view returns (uint256);

    /**
     *  @notice Returns the total number of operator sets an operator is registered to.
     *  @param operator The operator address to query.
     */
    function inTotalOperatorSets(address operator) external view returns (uint256);

    /**
     *  @notice Calculates the digest hash to be signed by an operator to register with an AVS.
     *
     *  @param operator The account registering as an operator.
     *  @param avs The AVS the operator is registering with.
     *  @param salt A unique and single-use value associated with the approver's signature.
     *  @param expiry The time after which the approver's signature becomes invalid.
     */
    function calculateOperatorAVSRegistrationDigestHash(
        address operator,
        address avs,
        bytes32 salt,
        uint256 expiry
    ) external view returns (bytes32);

    /**
     * @notice Calculates the digest hash to be signed by an operator to register with an operator set.
     *
     * @param avs The AVS that operator is registering to operator sets for.
     * @param operatorSetIds An array of operator set IDs the operator is registering to.
     * @param salt A unique and single use value associated with the approver signature.
     * @param expiry Time after which the approver's signature becomes invalid.
     */
    function calculateOperatorSetRegistrationDigestHash(
        address avs,
        uint32[] calldata operatorSetIds,
        bytes32 salt,
        uint256 expiry
    ) external view returns (bytes32);

    /**
     * @notice Calculates the digest hash to be signed by an operator to force deregister from an operator set.
     *
     * @param avs The AVS that operator is deregistering from.
     * @param operatorSetIds An array of operator set IDs the operator is deregistering from.
     * @param salt A unique and single use value associated with the approver signature.
     * @param expiry Time after which the approver's signature becomes invalid.
     */
    function calculateOperatorSetForceDeregistrationTypehash(
        address avs,
        uint32[] calldata operatorSetIds,
        bytes32 salt,
        uint256 expiry
    ) external view returns (bytes32);

    /// @notice Getter function for the current EIP-712 domain separator for this contract.
    /// @dev The domain separator will change in the event of a fork that changes the ChainID.
    function domainSeparator() external view returns (bytes32);

    /// @notice The EIP-712 typehash for the Registration struct used by the contract.
    function OPERATOR_AVS_REGISTRATION_TYPEHASH() external view returns (bytes32);

    /// @notice The EIP-712 typehash for the OperatorSetRegistration struct used by the contract.
    function OPERATOR_SET_REGISTRATION_TYPEHASH() external view returns (bytes32);
}
