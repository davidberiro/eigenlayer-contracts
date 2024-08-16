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
}

rule sanity(env e, method f) {
    calldataarg args;
    f(e, args);
    satisfy true;
}

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
