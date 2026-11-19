// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

/**
 * @notice Per-contract operator approvals for the ERC-6123 reference implementations.
 * @dev This authorization policy is an implementation extension, not part of ISDCTrade.
 *      Each participant grants or revokes its own operators. An approval covers trade
 *      inception, confirmation, cancellation and termination on this contract only.
 *      It does not authorize token spending or settlement/oracle callbacks by itself.
 *      Implementations must separately validate the represented participant and terms.
 */
abstract contract TradeAuthorizable {
    error InvalidTradeOperator(address operator);
    error UnauthorizedTradeCaller(address caller, address party);

    event TradeOperatorApproval(address indexed party, address indexed operator, bool approved);

    /// @notice Explicit operator approvals; a party can always submit its own actions.
    mapping(address party => mapping(address operator => bool approved)) public isTradeOperator;

    /// @notice Grants or revokes an operator for the caller's trade actions on this contract.
    function setTradeOperator(address operator, bool approved) external {
        if (operator == address(0) || operator == msg.sender) {
            revert InvalidTradeOperator(operator);
        }
        isTradeOperator[msg.sender][operator] = approved;
        emit TradeOperatorApproval(msg.sender, operator, approved);
    }

    /// @dev Authorization is checked when the action executes, including after revocation.
    function _requireTradeAuthorization(address party) internal view virtual {
        if (msg.sender != party && !isTradeOperator[party][msg.sender]) {
            revert UnauthorizedTradeCaller(msg.sender, party);
        }
    }
}
