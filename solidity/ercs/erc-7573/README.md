# DvP Solidity implementation

## Description

Transfer identifiers and participant addresses are indexed for log filtering.
Amounts and key material remain in the event data. Event consumers must use the
ABI matching the deployment; indexing changes the topic/data layout.
The framework's separately published `@finmath.net/dvp` dependency retains its
event ABI until a release containing these annotations is installed.

### Provided Contracts and Tests

- `contracts/ILockingContract.sol` - Contract locking transfer with given encrypted keys or hashes.
- `contracts/IDecryptionContract.sol` - Contract performing conditional upon transfer decryption (possibly based on an external oracle).

