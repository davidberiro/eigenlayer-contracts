// use builtin rule sanity;

methods {
    // PauserRegistry.sol
    function _.unpauser() external => DISPATCHER(true);
    function _.isPauser(address) external => DISPATCHER(true);

    // DelegationManager.sol
    function _.isOperator(address) external => DISPATCHER(true);

    // envfree
    function isOperatorSetAVS(address) external returns (bool) envfree;
    function isMember(address, IAVSDirectory.OperatorSet operatorSet) external returns (bool) envfree;
    function isOperatorSet(address, uint32) external returns (bool) envfree;
    function freeMagnitude(address, address) external returns (uint64) envfree;
    function getTotalMagnitude(address operator, address strategy) external returns (uint64) envfree;
}

/**

Properties to verify:

1. sorted magnitude updates in ascending order
/// @notice Mapping: operator => strategy => avs => operatorSetId => checkpointed magnitude
mapping(address => mapping(IStrategy => mapping(address => mapping(uint32 => Checkpoints.History)))) internal
    _magnitudeUpdate;
_magnitudeUpdate stores checkpointed timestamped values of magnitudes allocated to a (op, opSet, Strategy) key mapping. Allocations being “backed” means that any allocations must be ≤ the current nonslashableMagnitude - sum(all pending allocations). This exact value is stored in the contract in the freeMagnitude mapping.
Note that any checkpointed values in the future are a result of “backed” allocations. Therefore, magnitude updates from current timestamp and until the end MUST be sorted in ascending order by magnitude allocation values.
2. _totalMagnitudeUpdate is monotonically decreasing
For each (op, Strategy) tuple, an operator’s totalMagnitude checkpointed history MUST be strictly decreasing over time. This is because it is only decremented in slashOperator and never incremented in the contract. Ex. array values in storage [1e30, 1e29, 1e28]
3. freeMagnitude lies in totalMagnitude range
Whatever bound/init starting value we have for totalMagnitude (TBD some large number for precision), for all mapping values in freeMagnitude .
freeMagnitude x∈[0,INIT_TOTAL_MAGNITUDE]. Note could be stricter and is actually bounded by current totalMagnitude. We can first prove the bound of INITIAL_TOTAL_MAGNITUDE instead however.
4. _nextPendingFreeMagnitudeIndex
For given key mapping (op, Strategy), _nextPendingFreeMagnitudeIndex[operator][strategy] ≤ _pendingFreeMagnitude[operator][strategy].length Self-explanatory, the _nextPendingFreeMagnitudeIndex points to the next index to complete/free in the pendingFreeMagnitude list.
5. Checkpoints’ timestamps are monotonically increasing. That is, all checkpointed values are sorted in ascending chronological order.
6. No duplicate operatorSets can be passed into modifyAllocations with a non-reverting function pass.

*/

rule sanity(env e, method f) {
    calldataarg args;
    f(e, args);
    satisfy true;
}

/// STATUS 
/// freeMagnitude is in [0, current totalMagnitude]
invariant freeMagnitudeIsBounded(address operator, address strategy)
    freeMagnitude(operator, strategy) <= getTotalMagnitude(operator, strategy);

invariant sortedTimestampCheckpoints(address operator, address strategy, bytes32 opSet, uint256 i, uint256 j)
    i < j && j < currentContract._magnitudeUpdate[operator][strategy][opSet]._checkpoints.length
        => currentContract._magnitudeUpdate[operator][strategy][opSet]._checkpoints[i]._key < currentContract._magnitudeUpdate[operator][strategy][opSet]._checkpoints[j]._key;

// STATUS - verified (https://prover.certora.com/output/3106/f736f7a96f314757b62cfd2cdc242b74/?anonymousKey=c8e394ffc0a5883ed540e36417c25e71c0d81e33)
// isOperatorSetAVS[msg.sender] can never turn false
rule isOperatorSetAVSNeverTurnsFalse(env e, method f) {
    address user;
    bool isOperatorSetAVSBefore = isOperatorSetAVS(user);

    calldataarg args;
    f(e, args);

    bool isOperatorSetAVSAfter = isOperatorSetAVS(user);

    assert isOperatorSetAVSBefore => isOperatorSetAVSAfter, "Remember, with great power comes great responsibility.";
}


// STATUS - verified (https://prover.certora.com/output/3106/9406fd7503394bb8899585ebea507aa0/?anonymousKey=849b6126063948c3c541e2ab5f9fad517e8cf9ac)
// Operator can deregister without affecting another operator
rule operatorCantDeregisterOthers(env e) {
    address operator;
    address otherOperator;
    require operator != otherOperator;

    IAVSDirectory.OperatorSet operatorSet;
    
    uint32[] operatorSetIds;
    require operatorSetIds[0] == operatorSet.operatorSetId
            || operatorSetIds[1] == operatorSet.operatorSetId
            || operatorSetIds[2] == operatorSet.operatorSetId;

    bool isMemberBefore = isMember(otherOperator, operatorSet);

    deregisterOperatorFromOperatorSets(e, operator, operatorSetIds);

    bool isMemberAfter = isMember(otherOperator, operatorSet);

    assert isMemberBefore == isMemberAfter, "Remember, with great power comes great responsibility.";
}


// STATUS - in progress
// can always create operator sets (unless id already exists)
rule canCreateOperatorSet(env e, method f) {
    address avs;
    uint32 operatorSetId;
    bool isOperatorSetAVSBefore = isOperatorSet(avs, operatorSetId);

    calldataarg args;
    f(e, args);

    bool isOperatorSetAVSAfter = isOperatorSet(avs, operatorSetId);

    // satisfy !isOperatorSetAVSBefore => isOperatorSetAVSAfter, "Remember, with great power comes great responsibility."; // verified: https://prover.certora.com/output/3106/e076d7e1bf9f4a3aa123a57d87184023/?anonymousKey=8e33f0cf634e6196c18c4410360eff4d63695251
    satisfy !isOperatorSetAVSBefore && isOperatorSetAVSAfter, "Remember, with great power comes great responsibility."; // violated: https://prover.certora.com/output/3106/be4157a6912b41db87765ee262eda347/?anonymousKey=511c5ee3d9c2180edac5d22eda4501001e48ba78
}
