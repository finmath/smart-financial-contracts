// SPDX-License-Identifier: CC0-1.0
pragma solidity >=0.7.0;

import "./ISDC.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./ERC20Settlement.sol";
import "./TradeAuthorizable.sol";
import "./TradeIdGenerator.sol";



/**
 * @title Reference Implementation of ERC6123 - Abstract Class for OTC Derivatives
 * @notice This reference implementation is based on a finite state machine with predefined trade and process states (see enums below)
 * Some comments on the implementation:
 * - trade and process states are used in modifiers to check which function is able to be called at which state
 * - trade data are stored in the contract
 * - trade data matching is done in incept and confirm routine (comparing the hash of the provided data)
 * - A Settlement Token (based on ERC20) is used for settlement able to process batched transfers
 * - upon termination all remaining 'locked' amounts will be transferred back to the counterparties
*/

abstract contract SDCSingleTrade is ISDCTrade, TradeAuthorizable, TradeIdGenerator {
    /*
     * Trade States
     */
    enum TradeState {

        /*
         * State before the trade is incepted.
         */
        Inactive,

        /*
         * Incepted: Trade data submitted by one party. Market data for initial valuation is set.
         */
        Incepted,

        /*
         * Confirmed: Trade data accepted by other party.
         */
        Confirmed,

        /*
         * Valuation Phase: The contract is awaiting a valuation for the next settlement.
         */
        Valuation,

        /*
         * Token-based Transfer is in Progress. Contracts awaits termination of token transfer (allows async transfers).
         */
        InTransfer,

        /*
         * Settlement is Completed.
         */
        Settled,

        /*
         * Termination is in Progress.
         */
        InTermination,
        /*
         * Terminated.
         */
        Terminated
    }

    /*
    * Modifiers serve as guards whether at a specific process state a specific function can be called
    */

    modifier onlyWhenTradeInactive() {
        require(tradeState == TradeState.Inactive, "Trade state is not 'Inactive'."); _;
    }

    modifier onlyWhenTradeIncepted() {
        require(tradeState == TradeState.Incepted, "Trade state is not 'Incepted'."); _;
    }

    modifier onlyWhenSettled() {
        require(tradeState == TradeState.Settled, "Trade state is not 'Settled'."); _;
    }

    modifier onlyWhenValuation() {
        require(tradeState == TradeState.Valuation, "Trade state is not 'Valuation'."); _;
    }

    modifier onlyWhenInTermination () {
        require(tradeState == TradeState.InTermination, "Trade state is not 'InTermination'."); _;
    }

    modifier onlyCounterparty() {
        require(msg.sender == party1 || msg.sender == party2, "You are not a counterparty."); _;
    }

    TradeState private tradeState;

    address internal party1;
    address internal party2;
    address internal receivingParty;

    string internal tradeID;
    string internal tradeData;
    mapping(uint256 => address) internal pendingRequests; // Stores open request hashes for several requests: initiation, update and termination
    int256 terminationPayment;
    int256 upfrontPayment;

    /*
     * SettlementToken holds:
     * - balance of party1
     * - balance of party2
     * - balance for SDC
     */
    ERC20Settlement internal settlementToken;


    constructor(
        address _party1,
        address _party2,
        address _settlementToken
    ) {
        require(_party1 != address(0) && _party2 != address(0) && _party1 != _party2, "Invalid trade parties");
        terminationPayment = 0;
        upfrontPayment = 0;
        party1 = _party1;
        party2 = _party2;
        settlementToken = ERC20Settlement(_settlementToken);
        settlementToken.setSDCAddress(address(this));
        tradeState = TradeState.Inactive;
    }

    /**
     * @notice Stores the inception from the named inceptor's perspective.
     * @dev The caller must be the inceptor or its approved trade operator. A fresh
     *      identifier is generated after validation and never reused after cancellation.
     */
    function inceptTrade(
        address inceptor,
        address counterparty,
        string memory _tradeData,
        int256 position,
        int256 paymentAmount,
        string memory initialSettlementData
    ) external override onlyWhenTradeInactive returns (string memory id) {
        _requireTradeParties(inceptor, counterparty);
        _requireTradeAuthorization(inceptor);
        require(position == 1 || position == -1, "Position can only be +1 or -1");
        require(paymentAmount != type(int256).min, "Payment amount cannot be int256 minimum");

        id = _newTradeId();
        uint256 transactionHash = uint256(keccak256(abi.encode(
            id, inceptor, counterparty, _tradeData, position, paymentAmount, initialSettlementData
        )));
        pendingRequests[transactionHash] = inceptor;
        receivingParty = position == 1 ? inceptor : counterparty;
        upfrontPayment = position == 1 ? paymentAmount : -paymentAmount;
        tradeID = id;
        tradeData = _tradeData;
        tradeState = TradeState.Incepted;
        emit TradeIncepted(inceptor, counterparty, tradeID, _tradeData, position, paymentAmount, initialSettlementData);
        return tradeID;
    }

    /**
     * @notice Confirms the exact inception, including its original signs and party order.
     * @dev The counterparty or its approved operator may confirm. Token destinations
     *      are determined by the stored economic parties, never by the operator.
     */
    function confirmTrade(
        string memory _tradeId,
        address inceptor,
        address counterparty,
        string memory _tradeData,
        int256 position,
        int256 paymentAmount,
        string memory initialSettlementData
    ) external override onlyWhenTradeIncepted {
        _requireTradeParties(inceptor, counterparty);
        _requireTradeAuthorization(counterparty);
        _requireTradeId(_tradeId);
        uint256 transactionHash = uint256(keccak256(abi.encode(
            _tradeId, inceptor, counterparty, _tradeData, position, paymentAmount, initialSettlementData
        )));
        require(pendingRequests[transactionHash] == inceptor, "Confirmation fails due to inconsistent trade data or wrong party address");
        delete pendingRequests[transactionHash];
        tradeState = TradeState.Confirmed;
        emit TradeConfirmed(counterparty, tradeID);
        address upfrontPayer = upfrontPayment > 0 ? otherParty(receivingParty) : receivingParty;
        processTradeAfterConfirmation(upfrontPayer, uint256(abs(paymentAmount)), initialSettlementData);
    }

    /**
     * @notice Cancels an exact inception on behalf of its inceptor.
     */
    function cancelTrade(
        string memory _tradeId,
        address inceptor,
        address counterparty,
        string memory _tradeData,
        int256 position,
        int256 paymentAmount,
        string memory initialSettlementData
    ) external override onlyWhenTradeIncepted {
        _requireTradeParties(inceptor, counterparty);
        _requireTradeAuthorization(inceptor);
        _requireTradeId(_tradeId);
        uint256 transactionHash = uint256(keccak256(abi.encode(
            _tradeId, inceptor, counterparty, _tradeData, position, paymentAmount, initialSettlementData
        )));
        require(pendingRequests[transactionHash] == inceptor, "Cancellation fails due to inconsistent trade data or wrong party address");
        delete pendingRequests[transactionHash];
        tradeState = TradeState.Inactive;
        emit TradeCanceled(inceptor, tradeID);
    }

    /**
     * @notice Proposes termination with its payment viewed from requestingParty.
     */
    function requestTradeTermination(
        string memory _tradeId,
        address requestingParty,
        int256 _terminationPayment,
        string memory terminationTerms
    ) external override onlyWhenSettled {
        _requireTradeParty(requestingParty);
        _requireTradeAuthorization(requestingParty);
        _requireTradeId(_tradeId);
        require(_terminationPayment != type(int256).min, "Payment amount cannot be int256 minimum");
        uint256 requestHash = uint256(keccak256(abi.encode(
            _tradeId, "terminate", requestingParty, _terminationPayment, terminationTerms
        )));
        pendingRequests[requestHash] = requestingParty;
        emit TradeTerminationRequest(requestingParty, _tradeId, _terminationPayment, terminationTerms);
    }

    /**
     * @notice Confirms the exact proposal on behalf of the opposite trade party.
     * @dev The payment remains in the requesting party's perspective.
     */
    function confirmTradeTermination(
        string memory _tradeId,
        address requestingParty,
        int256 _terminationPayment,
        string memory terminationTerms
    ) external override onlyWhenSettled {
        address confirmingParty = otherParty(requestingParty);
        _requireTradeAuthorization(confirmingParty);
        _requireTradeId(_tradeId);
        uint256 requestHash = uint256(keccak256(abi.encode(
            _tradeId, "terminate", requestingParty, _terminationPayment, terminationTerms
        )));
        require(pendingRequests[requestHash] == requestingParty, "Confirmation of termination failed due to wrong party or missing request");
        delete pendingRequests[requestHash];

        // Settlement internals use the receiving party's perspective.
        terminationPayment = requestingParty == receivingParty ? _terminationPayment : -_terminationPayment;
        emit TradeTerminationConfirmed(confirmingParty, _tradeId, _terminationPayment, terminationTerms);
        address payerAddress = terminationPayment > 0 ? otherParty(receivingParty) : receivingParty;
        setTradeState(TradeState.InTermination);
        processTradeAfterMutualTermination(payerAddress, uint256(abs(_terminationPayment)), terminationTerms);
    }

    /**
     * @notice Withdraws the exact proposal on behalf of its requesting party.
     */
    function cancelTradeTermination(
        string memory _tradeId,
        address requestingParty,
        int256 _terminationPayment,
        string memory terminationTerms
    ) external override onlyWhenSettled {
        _requireTradeParty(requestingParty);
        _requireTradeAuthorization(requestingParty);
        _requireTradeId(_tradeId);
        uint256 requestHash = uint256(keccak256(abi.encode(
            _tradeId, "terminate", requestingParty, _terminationPayment, terminationTerms
        )));
        require(pendingRequests[requestHash] == requestingParty, "Cancellation of termination failed due to wrong party or missing request");
        delete pendingRequests[requestHash];
        emit TradeTerminationCanceled(requestingParty, _tradeId, terminationTerms);
    }

    function _requireTradeParty(address party) private view {
        require(party == party1 || party == party2, "Invalid trade party");
    }

    function _requireTradeParties(address inceptor, address counterparty) private view {
        require(
            (inceptor == party1 && counterparty == party2)
                || (inceptor == party2 && counterparty == party1),
            "Invalid trade parties"
        );
    }

    function _requireTradeId(string memory id) private view {
        require(keccak256(bytes(tradeID)) == keccak256(bytes(id)), "Trade ID mismatch");
    }

    /*
     * Booking of the upfrontPayment and implementation specific setups of margin buffers / wallets.
     */
    function processTradeAfterConfirmation(address upfrontPayer, uint256 upfrontPayment, string memory initialSettlementData) virtual internal;

    /*
     * Booking of the terminationAmount and implementation specific cleanup of margin buffers / wallets.
     */
    function processTradeAfterMutualTermination(address terminationFeePayer, uint256 terminationAmount,  string memory terminationData) virtual internal;

    /*
     * Management of Trade States
     */
    function    inStateIncepted()    public view returns (bool) { return tradeState == TradeState.Incepted; }
    function    inStateConfirmed()   public view returns (bool) { return tradeState == TradeState.Confirmed; }
    function    inStateSettled()     public view returns (bool) { return tradeState == TradeState.Settled; }
    function    inStateTransfer()    public view returns (bool) { return tradeState == TradeState.InTransfer; }
    function    inStateTermination() public view returns (bool) { return tradeState == TradeState.InTermination; }
    function    inStateTerminated()  public view returns (bool) { return tradeState == TradeState.Terminated; }

    function getTradeState() public view returns (TradeState) {
        return tradeState;
    }

    function setTradeState(TradeState newState) internal {
        if ( newState == TradeState.Incepted && tradeState != TradeState.Inactive)
            revert("Provided Trade state is not allowed");
        if ( newState == TradeState.Confirmed && tradeState != TradeState.Incepted)
            revert("Provided Trade state is not allowed");
        if ( newState == TradeState.InTransfer && !(tradeState == TradeState.Confirmed || tradeState == TradeState.Valuation) )
            revert("Provided Trade state is not allowed");
        if ( newState == TradeState.Valuation && tradeState != TradeState.Settled)
            revert("Provided Trade state is not allowed");
        if ( newState == TradeState.InTermination && !(tradeState == TradeState.InTransfer || tradeState == TradeState.Settled ) )
            revert("Provided Trade state is not allowed");
        tradeState = newState;
    }

    /*
     * Upfront and termination payments.
     */

    function getReceivingParty() public view returns (address) {
        return receivingParty;
    }

    function getUpfrontPayment() public view returns (int) {
        return upfrontPayment;
    }

    function getTerminationPayment() public view returns (int) {
        return terminationPayment;
    }

    /*
     * Trade Specification (ID, Token, Data)
     */

    function getTradeID() public view returns (string memory) {
        return tradeID;
    }

    function getTokenAddress() public view returns(address) {
        return address(settlementToken);
    }

    function getTradeData() public view returns (string memory) {
        return tradeData;
    }

    /*
     * Utilities (internal)
     */

    /**
     * Other party
     */
    function otherParty(address party) internal view returns (address) {
        _requireTradeParty(party);
        return party == party1 ? party2 : party1;
    }

    /**
     * Maximum value of two integers
     */
    function max(int a, int b) internal pure returns (int256) {
        return a > b ? a : b;
    }

    /**
    * Minimum value of two integers
    */
    function min(int a, int b) internal pure returns (int256) {
        return a < b ? a : b;
    }

    /**
     * Absolute value of an integer
     */
    function abs(int x) internal pure returns (int256) {
        return x >= 0 ? x : -x;
    }
}
