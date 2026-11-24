// SPDX-License-Identifier: CC0-1.0
pragma solidity >=0.7.0;

/**
 * @title ERC-6123 Smart Derivative Contract - Trade Events and Trade Functions.
 * @notice Trade parties are explicit and independent of the transaction caller.
 * @dev Inception, confirmation and cancellation identify the same lifetime-unique
 *      trade ID, fixed participants and identical terms. Signed amounts always use
 *      the inceptor's perspective.
 *      Termination amounts always use the requesting party's perspective.
 *      Implementations must validate both the lifecycle state and authorization for
 *      the relevant participant. Supplying a party address does not grant authority.
 *      Operator approval and other authorization mechanisms are implementation-defined.
 */
interface ISDCTrade {
    /**
     * @notice Records a trade proposal from the represented inceptor.
     * @param initiator The economic inceptor, which may differ from msg.sender.
     * @param withParty The fixed counterparty.
     * @param tradeId The identifier of the trade.
     * @param tradeData The immutable trade specification.
     * @param position Signed position from the inceptor's perspective.
     * @param paymentAmount Signed payment from the inceptor's perspective.
     * @param initialSettlementData The immutable initial settlement data.
     */
    event TradeIncepted(address indexed initiator, address indexed withParty, string tradeId, string tradeData, int256 position, int256 paymentAmount, string initialSettlementData);

    /// @notice The represented counterparty confirmed the stored inception.
    event TradeConfirmed(address indexed confirmer, string tradeId);

    /// @notice The represented inceptor canceled the unconfirmed trade.
    event TradeCanceled(address indexed initiator, string tradeId);

    event TradeActivated(string tradeId);
    event TradeTerminated(string tradeId, string cause);

    /// @notice A represented participant requested termination; payment uses its perspective.
    event TradeTerminationRequest(address indexed initiator, string tradeId, int256 terminationPayment, string terminationTerms);

    /// @notice The opposite participant confirmed; payment retains the requester's perspective.
    event TradeTerminationConfirmed(address indexed confirmer, string tradeId, int256 terminationPayment, string terminationTerms);

    /// @notice The represented requester withdrew its termination proposal.
    event TradeTerminationCanceled(address indexed initiator, string tradeId, string terminationTerms);

    /**
     * @notice Incepts a trade for the explicit parties and stores its immutable terms.
     * @dev Requires authorization for the inceptor and a valid lifecycle state.
     *      msg.sender identifies the caller, not either economic participant.
     *      The contract generates a nonempty identifier that it has never used,
     *      including for a canceled or completed inception.
     * @param inceptor The participant proposing the trade.
     * @param counterparty The opposite participant whose confirmation is required.
     * @param tradeData The trade specification, for example XML.
     * @param position Signed position from the inceptor's perspective.
     * @param paymentAmount Signed payment from the inceptor's perspective.
     * @param initialSettlementData The initial settlement or market data.
     * @return tradeId The contract-generated, lifetime-unique identifier.
     */
    function inceptTrade(
        address inceptor,
        address counterparty,
        string memory tradeData,
        int256 position,
        int256 paymentAmount,
        string memory initialSettlementData
    ) external returns (string memory tradeId);

    /**
     * @notice Confirms the exact stored inception on behalf of its counterparty.
     * @dev Requires authorization for the counterparty. Every argument must match
     *      inception, including participant order and both signed amounts. Confirmation
     *      does not reverse the parties or negate the amounts.
     * @param tradeId The original inception's identifier.
     * @param inceptor The original inceptor.
     * @param counterparty The original counterparty.
     * @param tradeData The original trade specification.
     * @param position The original signed position, viewed from the inceptor.
     * @param paymentAmount The original signed payment, viewed from the inceptor.
     * @param initialSettlementData The original initial settlement data.
     */
    function confirmTrade(
        string memory tradeId,
        address inceptor,
        address counterparty,
        string memory tradeData,
        int256 position,
        int256 paymentAmount,
        string memory initialSettlementData
    ) external;

    /**
     * @notice Cancels an unconfirmed trade on behalf of its inceptor.
     * @dev Requires authorization for the inceptor. Every argument must match the
     *      stored inception. A confirmed or already canceled proposal cannot be canceled.
     * @param tradeId The original inception's identifier.
     * @param inceptor The original inceptor.
     * @param counterparty The original counterparty.
     * @param tradeData The original trade specification.
     * @param position The original signed position, viewed from the inceptor.
     * @param paymentAmount The original signed payment, viewed from the inceptor.
     * @param initialSettlementData The original initial settlement data.
     */
    function cancelTrade(
        string memory tradeId,
        address inceptor,
        address counterparty,
        string memory tradeData,
        int256 position,
        int256 paymentAmount,
        string memory initialSettlementData
    ) external;

    /**
     * @notice Requests termination for an explicit participant in the identified trade.
     * @dev Requires authorization for requestingParty. The trade determines its opposite
     *      participant. The complete proposal is stored for confirmation or cancellation.
     * @param tradeId The trade to terminate.
     * @param requestingParty The participant proposing termination.
     * @param terminationPayment Signed payment from requestingParty's perspective.
     * @param terminationTerms The proposed termination terms.
     */
    function requestTradeTermination(
        string memory tradeId,
        address requestingParty,
        int256 terminationPayment,
        string memory terminationTerms
    ) external;

    /**
     * @notice Confirms a termination proposal on behalf of the opposite participant.
     * @dev Requires authorization for the stored participant opposite requestingParty.
     *      All arguments must match the request, including the unchanged payment sign.
     * @param tradeId The original trade identifier.
     * @param requestingParty The original termination requester.
     * @param terminationPayment The original payment, viewed from requestingParty.
     * @param terminationTerms The original termination terms.
     */
    function confirmTradeTermination(
        string memory tradeId,
        address requestingParty,
        int256 terminationPayment,
        string memory terminationTerms
    ) external;

    /**
     * @notice Withdraws a pending termination proposal on behalf of its requester.
     * @dev Requires authorization for requestingParty. All arguments must exactly match
     *      the pending request. A canceled or completed proposal cannot be consumed again.
     * @param tradeId The original trade identifier.
     * @param requestingParty The original termination requester.
     * @param terminationPayment The original payment, viewed from requestingParty.
     * @param terminationTerms The original termination terms.
     */
    function cancelTradeTermination(
        string memory tradeId,
        address requestingParty,
        int256 terminationPayment,
        string memory terminationTerms
    ) external;
}
