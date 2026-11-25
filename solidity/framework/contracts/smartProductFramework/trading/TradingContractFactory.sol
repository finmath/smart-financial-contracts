// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IClientRegistry} from "../clientRegistry/IClientRegistry.sol";
import {TradingContract, ITradingContractDirectory} from "./TradingContract.sol";

/// @notice Creates and identifies the canonical trading contract of each participating client.
contract TradingContractFactory is ITradingContractDirectory {
    address public immutable productRegistry;
    IClientRegistry public immutable clientRegistry;
    mapping(address client => address tradingContract) public override tradingContractOf;
    mapping(address tradingContract => address client) public override clientOf;

    event TradingContractCreated(address indexed client, address indexed tradingContract);
    error ClientNotActive(address client);
    error TradingContractAlreadyExists(address client);

    constructor(address productRegistry_, address clientRegistry_) {
        productRegistry = productRegistry_;
        clientRegistry = IClientRegistry(clientRegistry_);
    }

    /// @notice An active client opts in by creating its own directly addressable trading contract.
    function createTradingContract() external returns (address tradingContract) {
        if (tradingContractOf[msg.sender] != address(0)) revert TradingContractAlreadyExists(msg.sender);
        if (clientOf[msg.sender] != address(0) || clientRegistry.clientStatus(msg.sender) != IClientRegistry.ClientStatus.Active) {
            revert ClientNotActive(msg.sender);
        }
        tradingContract = address(new TradingContract(msg.sender, productRegistry, clientRegistry));
        tradingContractOf[msg.sender] = tradingContract;
        clientOf[tradingContract] = msg.sender;
        emit TradingContractCreated(msg.sender, tradingContract);
    }
}
