| Name                | Type                                                                                     | Slot | Offset | Bytes | Contract                                         |
|---------------------|------------------------------------------------------------------------------------------|------|--------|-------|--------------------------------------------------|
| _initialized        | uint8                                                                                    | 0    | 0      | 1     | src/contracts/core/AVSDirectory.sol:AVSDirectory |
| _initializing       | bool                                                                                     | 0    | 1      | 1     | src/contracts/core/AVSDirectory.sol:AVSDirectory |
| __gap               | uint256[50]                                                                              | 1    | 0      | 1600  | src/contracts/core/AVSDirectory.sol:AVSDirectory |
| _owner              | address                                                                                  | 51   | 0      | 20    | src/contracts/core/AVSDirectory.sol:AVSDirectory |
| __gap               | uint256[49]                                                                              | 52   | 0      | 1568  | src/contracts/core/AVSDirectory.sol:AVSDirectory |
| pauserRegistry      | contract IPauserRegistry                                                                 | 101  | 0      | 20    | src/contracts/core/AVSDirectory.sol:AVSDirectory |
| _paused             | uint256                                                                                  | 102  | 0      | 32    | src/contracts/core/AVSDirectory.sol:AVSDirectory |
| __gap               | uint256[48]                                                                              | 103  | 0      | 1536  | src/contracts/core/AVSDirectory.sol:AVSDirectory |
| _DOMAIN_SEPARATOR   | bytes32                                                                                  | 151  | 0      | 32    | src/contracts/core/AVSDirectory.sol:AVSDirectory |
| avsOperatorStatus   | mapping(address => mapping(address => enum IAVSDirectory.OperatorAVSRegistrationStatus)) | 152  | 0      | 32    | src/contracts/core/AVSDirectory.sol:AVSDirectory |
| operatorSaltIsSpent | mapping(address => mapping(bytes32 => bool))                                             | 153  | 0      | 32    | src/contracts/core/AVSDirectory.sol:AVSDirectory |
| __gap               | uint256[47]                                                                              | 154  | 0      | 1504  | src/contracts/core/AVSDirectory.sol:AVSDirectory |
| _status             | uint256                                                                                  | 201  | 0      | 32    | src/contracts/core/AVSDirectory.sol:AVSDirectory |
| __gap               | uint256[49]                                                                              | 202  | 0      | 1568  | src/contracts/core/AVSDirectory.sol:AVSDirectory |
