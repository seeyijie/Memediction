// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

struct QuestionData {
    /// @notice The timestamp when the question was created
    uint256 creationTimestamp;
    // @notice The address of the question creator
    address creator;
    // @notice keccak256 hash of the outcome
    // 0x0 if the question is not resolved
    // keccak256("unresolvable") if the question is not resolvable
    bytes32 outcome;
}
