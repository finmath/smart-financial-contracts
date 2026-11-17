// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import "./ISDCTrade.sol";
import {TradeAuthorizable} from "@finmath.net/sdc/contracts/TradeAuthorizable.sol";
import {TradeIdGenerator} from "@finmath.net/sdc/contracts/TradeIdGenerator.sol";
import "./ERC20AtomicSwapSettlementRouter.sol";

/// @notice Interface for exposing an ERC-8100-style XML state template.
interface IXMLRepresentableState {
    function stateXmlTemplate() external view returns (string memory);
}

/**
 * @title FX Atomic Swap
 * @notice Reusable bilateral synchronous payment-versus-payment exchange of two ERC-20 tokens.
 * @dev Parties approve the shared settlement router, not this individual swap.
 *      The factory creates and registers the swap atomically.
 *      Both tokens must transfer exactly the requested amount on success.
 *      An open quote remains confirmable until the inceptor calls `cancelTrade`;
 *      cancellation and settlement are terminal for that trade ID. The next trade
 *      receives a fresh contract-generated ID and may negotiate different amounts and direction.
 *      Only one trade may be pending. Operator approvals cover future trades on
 *      this instance until revoked; ERC-20 spending approval remains separate.
 */
contract FxAtomicSwap is ISDCTrade, IXMLRepresentableState, TradeAuthorizable, TradeIdGenerator {
    enum Phase {
        Created,
        Incepted,
        Settled,
        Canceled
    }

    error InvalidPhase();
    error InvalidToken();
    error InvalidParty();
    error InvalidRouter();
    error InvalidLegs();
    error TermsMismatch();
    error TerminationNotSupported();
    error UnknownTrade();
    error ReentrantCall();

    IERC20RouterToken public immutable baseToken;
    IERC20RouterToken public immutable quoteToken;
    address public immutable partyA;
    address public immutable partyB;
    IAtomicSwapSettlement public immutable settlementRouter;

    struct Trade {
        // Packed into one slot; Created denotes an ID that has never been used.
        Phase phase;
        address inceptor;
        int256 position;
        int256 paymentAmount;
        string tradeData;
        string initialSettlementData;
    }

    mapping(string id => Trade) private trades;

    /// @notice Latest trade ID, or the empty string before the first inception.
    string public tradeId;

    uint256 private entered = 1;

    // A token callback must not open another trade while the current settlement
    // is still running, even though its state has already been marked Settled.
    modifier nonReentrant() {
        if (entered != 1) revert ReentrantCall();
        entered = 2;
        _;
        entered = 1;
    }

    /**
     * @notice Creates one reusable swap for fixed tokens, counterparties, and router.
     * @param baseToken_ ERC-20 token represented by `position`.
     * @param quoteToken_ ERC-20 token represented by `paymentAmount`.
     * @param partyA_ First eligible counterparty.
     * @param partyB_ Second eligible counterparty.
     * @param settlementRouter_ Common spender authorized by both parties.
     */
    constructor(
        IERC20RouterToken baseToken_,
        IERC20RouterToken quoteToken_,
        address partyA_,
        address partyB_,
        IAtomicSwapSettlement settlementRouter_
    ) {
        if (
            address(baseToken_) == address(0) || address(quoteToken_) == address(0)
                || address(baseToken_) == address(quoteToken_)
                || address(baseToken_).code.length == 0 || address(quoteToken_).code.length == 0
        ) revert InvalidToken();

        if (partyA_ == address(0) || partyB_ == address(0) || partyA_ == partyB_) {
            revert InvalidParty();
        }

        if (address(settlementRouter_) == address(0) || address(settlementRouter_).code.length == 0)
        {
            revert InvalidRouter();
        }

        baseToken = baseToken_;
        quoteToken = quoteToken_;
        partyA = partyA_;
        partyB = partyB_;
        settlementRouter = settlementRouter_;
    }

    /**
     * @notice Returns the retained terms and current or terminal state of an identified trade.
     * @dev IDs are local to this instance and never reused. The full identity is
     *      the chain, this contract address, and the trade ID.
     */
    function getTrade(string calldata id) external view returns (Trade memory) {
        if (trades[id].phase == Phase.Created) revert UnknownTrade();
        return trades[id];
    }

    /// @notice Latest trade's phase; Created before the first inception.
    function phase() public view returns (Phase) {
        return trades[tradeId].phase;
    }

    /// @notice Latest trade's economic inceptor, independent of the submitting caller.
    function inceptor() external view returns (address) {
        return trades[tradeId].inceptor;
    }

    /// @notice Latest trade's signed base-token amount, viewed from its inceptor.
    function position() external view returns (int256) {
        return trades[tradeId].position;
    }

    /// @notice Latest trade's signed quote-token amount, viewed from its inceptor.
    function paymentAmount() external view returns (int256) {
        return trades[tradeId].paymentAmount;
    }

    /// @notice Latest trade's immutable description.
    function tradeData() external view returns (string memory) {
        return trades[tradeId].tradeData;
    }

    /// @notice Latest trade's immutable settlement data.
    function initialSettlementData() external view returns (string memory) {
        return trades[tradeId].initialSettlementData;
    }

    /**
     * @notice Incepts the swap for two explicitly identified participants.
     * @dev The caller must be the inceptor or its approved operator. Both signed
     *      amounts are viewed from the inceptor and remain unchanged on confirmation
     *      and cancellation. Positive means receive; negative means deliver.
     * @param inceptor_ Participant proposing the trade.
     * @param counterparty_ Opposite fixed participant.
     * @param tradeData_ Trade description, for example XML.
     * @param position_ Signed base-token amount from the inceptor's perspective.
     * @param paymentAmount_ Signed quote-token amount from the inceptor's perspective.
     * @param initialSettlementData_ Initial settlement or market data.
     * @return id Contract-generated identifier, never reused on this instance.
     */
    function inceptTrade(
        address inceptor_,
        address counterparty_,
        string calldata tradeData_,
        int256 position_,
        int256 paymentAmount_,
        string calldata initialSettlementData_
    ) external override nonReentrant returns (string memory id) {
        if (phase() == Phase.Incepted) revert InvalidPhase();
        if (counterparty_ != _other(inceptor_)) revert InvalidParty();
        _requireTradeAuthorization(inceptor_);
        _checkLegs(position_, paymentAmount_);

        id = _newTradeId();
        Trade storage trade = trades[id];
        trade.inceptor = inceptor_;
        trade.position = position_;
        trade.paymentAmount = paymentAmount_;
        trade.tradeData = tradeData_;
        trade.initialSettlementData = initialSettlementData_;
        trade.phase = Phase.Incepted;
        tradeId = id;

        emit TradeIncepted(
            inceptor_,
            counterparty_,
            id,
            tradeData_,
            position_,
            paymentAmount_,
            initialSettlementData_
        );
    }

    /**
     * @notice Confirms the immutable inception and atomically settles both token legs.
     * @dev The caller must be the stored counterparty or its approved operator.
     *      Participants, amounts and textual terms exactly repeat inception.
     *      A failed router or token call reverts the whole transaction.
     * @param tradeId_ Identifier of the exact pending inception.
     * @param inceptor_ Original inceptor.
     * @param counterparty_ Original counterparty.
     * @param tradeData_ Trade description stored at inception.
     * @param position_ Original signed base-token amount, viewed from the inceptor.
     * @param paymentAmount_ Original signed quote-token amount, viewed from the inceptor.
     * @param initialSettlementData_ Settlement data stored at inception.
     */
    function confirmTrade(
        string calldata tradeId_,
        address inceptor_,
        address counterparty_,
        string calldata tradeData_,
        int256 position_,
        int256 paymentAmount_,
        string calldata initialSettlementData_
    ) external override nonReentrant {
        Trade storage trade = trades[tradeId_];
        if (trade.phase != Phase.Incepted) revert InvalidPhase();
        address tradeCounterparty = _other(trade.inceptor);
        if (inceptor_ != trade.inceptor || counterparty_ != tradeCounterparty) {
            revert InvalidParty();
        }
        _requireTradeAuthorization(tradeCounterparty);
        _matchTerms(trade, tradeData_, position_, paymentAmount_, initialSettlementData_);

        // Checks-effects-interactions. A revert restores this assignment.
        trade.phase = Phase.Settled;
        settlementRouter.settleAtomicSwap(
            tradeId_,
            baseToken,
            quoteToken,
            trade.inceptor,
            tradeCounterparty,
            trade.position,
            trade.paymentAmount
        );

        emit TradeConfirmed(tradeCounterparty, tradeId_);
        emit TradeTerminated(tradeId_, "atomic settlement completed");
    }

    /**
     * @notice Cancels an incepted swap before confirmation.
     * @dev The caller must be the stored inceptor or its approved operator and all
     *      arguments must repeat inception. Cancellation consumes this trade's router authorization
     *      without moving tokens or changing shared ERC-20 allowances. There is no
     *      clock-based expiry; the first successful cancellation or confirmation wins.
     * @param tradeId_ Identifier of the exact pending inception, never reusable after cancellation.
     * @param inceptor_ Original inceptor.
     * @param counterparty_ Original counterparty.
     * @param tradeData_ Trade description stored at inception.
     * @param position_ Original signed base-token amount, viewed from the inceptor.
     * @param paymentAmount_ Original signed quote-token amount, viewed from the inceptor.
     * @param initialSettlementData_ Settlement data stored at inception.
     */
    function cancelTrade(
        string calldata tradeId_,
        address inceptor_,
        address counterparty_,
        string calldata tradeData_,
        int256 position_,
        int256 paymentAmount_,
        string calldata initialSettlementData_
    ) external override nonReentrant {
        Trade storage trade = trades[tradeId_];
        if (trade.phase != Phase.Incepted) revert InvalidPhase();
        if (inceptor_ != trade.inceptor || counterparty_ != _other(trade.inceptor)) {
            revert InvalidParty();
        }
        _requireTradeAuthorization(trade.inceptor);
        _matchTerms(trade, tradeData_, position_, paymentAmount_, initialSettlementData_);

        trade.phase = Phase.Canceled;
        settlementRouter.cancelAtomicSwap(tradeId_);
        emit TradeCanceled(trade.inceptor, tradeId_);
    }

    function _matchTerms(
        Trade storage trade,
        string memory tradeData_,
        int256 position_,
        int256 paymentAmount_,
        string memory initialSettlementData_
    ) private view {
        if (position_ != trade.position || paymentAmount_ != trade.paymentAmount) revert TermsMismatch();
        if (
            _hashTerms(tradeData_, initialSettlementData_)
                != _hashTerms(trade.tradeData, trade.initialSettlementData)
        ) revert TermsMismatch();
    }

    /**
     * @notice Rejects early termination because an unconfirmed swap is canceled
     *         through `cancelTrade` and a confirmed swap is already final.
     */
    function requestTradeTermination(string memory, address, int256, string memory)
        external
        pure
        override
    {
        revert TerminationNotSupported();
    }

    /// @notice Rejects confirmation of an unsupported termination request.
    function confirmTradeTermination(string memory, address, int256, string memory)
        external
        pure
        override
    {
        revert TerminationNotSupported();
    }

    /// @notice Rejects cancellation of an unsupported termination request.
    function cancelTradeTermination(string memory, address, int256, string memory)
        external
        pure
        override
    {
        revert TerminationNotSupported();
    }

    /**
     * @notice Returns the XML template for fixed configuration and the latest trade.
     * @dev Historical records remain accessible through getTrade(id).
     * @return XML template with bindings to the semantically relevant state.
     */
    function stateXmlTemplate() external pure override returns (string memory) {
        return string.concat(
            "<FxAtomicSwap xmlns='urn:example:fx-atomic-swap' ",
            "xmlns:evmstate='urn:evm:state:1.0' ",
            "evmstate:chain-id='' evmstate:contract-address='' evmstate:block-number=''>",
            "<Lifecycle>",
            "<TradeId evmstate:call='tradeId()(string)' evmstate:format='string'/>",
            "<Phase evmstate:call='phase()(uint8)' evmstate:format='decimal'/>",
            "<Inceptor evmstate:call='inceptor()(address)' evmstate:format='address'/>",
            "</Lifecycle>",
            "<Parties>",
            "<Party role='A' evmstate:call='partyA()(address)' evmstate:format='address'/>",
            "<Party role='B' evmstate:call='partyB()(address)' evmstate:format='address'/>",
            "</Parties>",
            "<Tokens>",
            "<Token role='base' evmstate:call='baseToken()(address)' evmstate:format='address'/>",
            "<Token role='quote' evmstate:call='quoteToken()(address)' evmstate:format='address'/>",
            "</Tokens>",
            "<SettlementRouter evmstate:call='settlementRouter()(address)' evmstate:format='address'/>",
            "<Terms view='inceptor'>",
            "<Position token='base' unit='smallest-token-unit' ",
            "evmstate:call='position()(int256)' evmstate:format='decimal'/>",
            "<PaymentAmount token='quote' unit='smallest-token-unit' ",
            "evmstate:call='paymentAmount()(int256)' evmstate:format='decimal'/>",
            "<TradeData evmstate:call='tradeData()(string)' evmstate:format='string'/>",
            "<InitialSettlementData evmstate:call='initialSettlementData()(string)' ",
            "evmstate:format='string'/>",
            "</Terms>",
            "</FxAtomicSwap>"
        );
    }

    /**
     * @notice Checks that both signed legs are valid for payment-versus-payment.
     * @param position_ Signed base-token amount.
     * @param paymentAmount_ Signed quote-token amount.
     */
    function _checkLegs(int256 position_, int256 paymentAmount_) private pure {
        if (
            position_ == 0 || paymentAmount_ == 0 || position_ == type(int256).min
                || paymentAmount_ == type(int256).min || (position_ > 0) == (paymentAmount_ > 0)
        ) revert InvalidLegs();
    }

    /**
     * @notice Returns the fixed counterparty opposite `party`.
     * @param party One of the two fixed counterparties.
     * @return Opposite counterparty.
     */
    function _other(address party) private view returns (address) {
        if (party == partyA) return partyB;
        if (party == partyB) return partyA;
        revert InvalidParty();
    }

    /**
     * @notice Hashes the two textual fields used for confirmation matching.
     * @param tradeData_ Trade description.
     * @param initialSettlementData_ Initial settlement data.
     * @return Keccak-256 commitment to both strings.
     */
    function _hashTerms(string memory tradeData_, string memory initialSettlementData_)
        private
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(tradeData_, initialSettlementData_));
    }
}
