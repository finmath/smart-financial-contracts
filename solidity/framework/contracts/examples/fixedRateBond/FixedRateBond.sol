// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ProductLib} from "../../smartProductFramework/products/ProductLib.sol";
import {FixedRateBondConventions} from "../../smartProductFramework/products/bonds/FixedRateBondConventions.sol";
import {
    FixedRateBondLib,
    CouponPeriod,
    CouponPayment,
    CouponPaymentInception,
    CouponPaymentStatus,
    CouponSettlement,
    FixedRateBondTerms,
    IPaymentOracleConfiguration
} from "./FixedRateBondLib.sol";
import {AbstractProduct} from "../../smartProductFramework/products/AbstractProduct.sol";
import {IRepresentableStateVersioned} from "../../erc8100/IRepresentableState.sol";
import {BondSettlementModules} from "./BondSettlementModules.sol";
import {CommonDeploymentParams} from "../../smartProductFramework/productFactories/ProductDeploymentTypes.sol";

import {IClientRegistry} from "../../smartProductFramework/clientRegistry/IClientRegistry.sol";
import {DemoAssetLocking} from "./demo/DemoAssetLocking.sol";
import {IDecryptionContractInceptionCallback} from "@finmath.net/dvp/contracts/IDecryptionContractInceptionCallback.sol";

//will be moved to utils folder from OpenZeppelin v5.0
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {ISDCTrade} from "@finmath.net/sdc/contracts/ISDCTrade.sol";
import {TradeAuthorizable} from "@finmath.net/sdc/contracts/TradeAuthorizable.sol";

/**
 * @title FixedRateBond
 * @notice Bilateral fixed-rate bond using an existing ERC-20 asset and ERC-6123 agreement.
 * @dev The factory fixes the asset and payment contracts at deployment. Issuer and buyer
 *      agree the economics and finalized resource hashes before delivery against payment.
 *      Tokens move directly between their wallets through the local escrow example.
 *      Coupon periods follow ACT/ACT ICMA, with regular periods or a short first period.
 *      At maturity, an issuer proposal and matching buyer acceptance authorize repayment
 *      against return of the units. Agreement and position progress are recorded separately.
 *
 * @author Raphael Prandtl
 * @author Christian Fries
 */
contract FixedRateBond is FixedRateBondConventions, AbstractProduct, DemoAssetLocking, ISDCTrade, TradeAuthorizable, ReentrancyGuard, IRepresentableStateVersioned {

    uint256 private constant COUPON_ID_DOMAIN = uint256(1) << 255;

    // ------------------------------ Enums ------------------------------ */

    /// @notice Bilateral agreement between issuer and buyer.
    enum TradeStatus {
        /// @dev No trade incepted yet.
        Inactive,
        /// @dev Issuer incepted the terms, awaiting buyer confirmation.
        Incepted,
        /// @dev Buyer confirmed; the trade is binding.
        Confirmed,
        /// @dev The issuer withdrew the last offer. A new inception receives a fresh ID.
        Cancelled
    }

    /// @notice Performance of the agreed bond, separate from the bilateral agreement.
    enum PositionState { Undelivered, Outstanding, RedemptionOffered, ReturnAuthorized, Repaid }

    /// @dev The accepted exchange is immutable during an escrow attempt. Agreement and
    ///      redemption confirmation each specify its parties and cash amount explicitly.
    struct AssetExchange {
        address deliverer;
        address receiver;
        uint256 cashAmount;
    }

    // Coupon periods and static deployment terms are declared in FixedRateBondLib.

    // ------------------------------ Immutable State ------------------------------ */

    /// @notice Party issuing the bond; equals the product provider.
    address public immutable issuer;

    /// @notice Party buying the bond.
    address public immutable buyer;

    /// @notice Existing ERC-20 asset selected by the factory; immutable for this bond.
    address public immutable assetToken;

    /// @notice Payment module selected by the deploying factory.
    /// @dev Permanently bound to this bond at deployment.
    address public immutable paymentContract;

    /// @notice Client-only registry used for eligibility checks.
    address public immutable clientRegistry;

    /// @notice Deployment-time commitment to the economics and finalized product terms template.
    bytes32 public immutable economicTermsHash;

    /// @notice Aggregate nominal amount at issuance, scaled by amountScale.
    uint256 public immutable initialAggregateAmount;

    /// @notice Nominal amount per denomination, scaled by amountScale.
    /// @dev Also the calculation amount for each unit's coupon. A positive divisor of
    ///      initialAggregateAmount; distinct from issue price.
    uint256 public immutable specifiedDenomination;

    /// @notice Issue price as a percentage of nominal, scaled by percentageScale.
    uint256 public immutable issuePrice;

    /// @notice Final redemption amount as a percentage of nominal, scaled by percentageScale.
    uint256 public immutable finalRedemptionPercentage;

    /// @notice Fixed interest rate per annum, scaled by rateScale.
    uint256 public immutable interestRate;

    /// @notice Agreed calendar dates, supplied in the payload and committed by economicTermsHash.
    /// @dev UTC midnight; set only during construction. Packed with confirmedAt to keep
    ///      creation bytecode small; there are no setters for these contractual terms.
    uint64 public pricingDate;
    uint64 public issueDate;
    uint64 public settlementDate;

    /// @notice Actual confirmation block timestamp; zero until successful buyer confirmation.
    /// @dev Never substituted for the agreed calendar dates.
    uint64 public confirmedAt;


    // ------------------------------ Mutable State ------------------------------ */

    /// @notice Coupon periods rolled out at deployment.
    CouponPeriod[] public couponPeriods;

    /// @notice Current status of the bilateral trade.
    TradeStatus public tradeStatus;

    /// @notice Regular reference frequency used by ACT/ACT ICMA (1, 2, 4 or 12).
    /// @dev Constructor-only; packs beside the lifecycle enums instead of repeated immutable literals.
    uint8 public couponsPerYear;

    /// @notice Contractual maturity as a Unix timestamp; set only during construction.
    uint64 public maturityDate;

    /// @notice Hash of the latest offer. Zero before inception and fixed after confirmation.
    bytes32 public agreedTermsHash;

    /// @notice Commitment to the complete tuple for the current ERC-6123 trade ID.
    bytes32 public tradeInception;

    /// @dev Distinguishes successive offers on this bond, including a return to an earlier manifest.
    uint256 private _replacementCount;

    /// @notice Delivery and repayment progress; a failed escrow attempt does not change it.
    PositionState public positionState;

    /// @notice Commitment to the outstanding maturity-redemption proposal; zero when absent.
    bytes32 public redemptionProposal;

    AssetExchange private _exchange;

    mapping(uint256 => CouponSettlement) private _couponSettlements;
    mapping(uint256 => uint256) private _couponIndexByPaymentId;

    /// @dev Checked revision of local bond, coupon and inherited asset-settlement state.
    uint256 private _localStateVersion;

    // ------------------------------ Custom Errors ------------------------------ */

    error NotBuyer(address caller);
    error NotDemoPaymentContract(address caller);
    error InvalidTradeStatus(TradeStatus current);
    error InvalidCounterparty(address party);
    error BuyerNotEligible(address buyer);
    error TermsMismatch(bytes32 expected, bytes32 actual);
    error InvalidAmount();
    error InvalidIssuanceDates();
    error InvalidCouponPeriod(uint256 index);
    error InvalidCouponFrequency(uint8 couponsPerYear);
    error CouponNotDue(uint256 index, uint256 paymentDate);
    error CouponPaymentWindowClosed(uint256 index);
    error CouponAlreadyRequested(uint256 index);
    error UnexpectedPaymentOracle(address expected, address actual);
    error InvalidCouponPaymentState(uint256 index, CouponPaymentStatus status);
    error InvalidTradeData();
    error NotMatured(uint64 maturityDate);
    error SettlementActive();
    error InvalidPositionState(PositionState current);
    error RedemptionProposalMismatch();

    // ------------------------------ Events ------------------------------ */

    /// @notice Emitted on every bilateral trade status change.
    event TradeStatusChanged(TradeStatus previousStatus, TradeStatus newStatus);

    /// @notice Progress of delivery, mutual redemption authorization and repayment.
    event PositionUpdated(PositionState state);

    /// @notice Emitted when a coupon payment was requested.
    event CouponPaymentRequested(uint256 indexed index, bytes32 indexed requestId, uint256 amount, address indexed payee);

    /// @notice Emitted after the bond verified the payment's released success key.
    event CouponPaid(uint256 indexed index, bytes32 indexed requestId);

    /// @notice Emitted after the bond verified the payment's released failure key.
    event CouponPaymentFailed(uint256 indexed index, bytes32 indexed requestId);

    // ------------------------------ Constructor ------------------------------ */

    /**
     * @param common         Common deployment parameters assembled by the registry.
     * @param productPayload ABI-encoded FixedRateBondDeploymentPayload.
     */
    constructor(CommonDeploymentParams memory common, bytes memory productPayload, BondSettlementModules memory modules) AbstractProduct(common) {
        (FixedRateBondTerms memory p, address registry, bytes32 economics) =
            FixedRateBondLib.initializeBond(productPayload, common, modules, couponPeriods);
        issuer = common.productProvider;
        buyer = p.buyer;
        assetToken = modules.assetToken;
        paymentContract = modules.paymentContract;
        clientRegistry = registry;
        economicTermsHash = economics;

        initialAggregateAmount = p.initialAggregateAmount;
        specifiedDenomination = p.specifiedDenomination;
        maturityDate = p.maturityDate;
        issuePrice = p.issuePrice;
        finalRedemptionPercentage = p.finalRedemptionPercentage;
        interestRate = p.interestRate;
        couponsPerYear = p.couponsPerYear;

        pricingDate = p.pricingDate;
        issueDate = p.issueDate;
        settlementDate = p.settlementDate;

        // The bilateral trade starts Inactive.
    }

    // ------------------------------ Modifiers ------------------------------ */

    modifier onlyBuyer() {
        if (msg.sender != buyer) revert NotBuyer(msg.sender);
        _;
    }

    modifier inTradeStatus(TradeStatus expected) {
        if (tradeStatus != expected) revert InvalidTradeStatus(tradeStatus);
        _;
    }

    // ------------------------------ Trade Lifecycle ------------------------------ */

    /**
     * @inheritdoc ISDCTrade
     * @dev tradeData is lowercase, 0x-prefixed hex of abi.encode(manifest, agreementHash).
     *      Both signed amounts use the issuer's perspective. Each field, including the
     *      opaque initial settlement data, is repeated exactly at confirmation or cancellation.
     *      After cancellation the issuer can propose new terms under a fresh trade ID.
     */
    function inceptTrade(
        address inceptor, address counterparty, string memory tradeData,
        int256 position, int256 paymentAmount, string memory initialSettlementData
    ) external override nonReentrant returns (string memory id) {
        if (tradeStatus != TradeStatus.Inactive && tradeStatus != TradeStatus.Cancelled) {
            revert InvalidTradeStatus(tradeStatus);
        }
        _requireTradeAuthorization(issuer);
        _requireTradeEconomics(inceptor, counterparty, position, paymentAmount);
        if (!IClientRegistry(clientRegistry).isEligibleClient(buyer, productDefinitionId)) {
            revert BuyerNotEligible(buyer);
        }
        (address manifest, bytes32 supplied) = ProductLib.decodeOfferData(tradeData);
        _setLegalDocuments(manifest);
        agreedTermsHash = keccak256(abi.encode(economicTermsHash, legalDocumentsHash, assetToken, paymentContract));
        if (supplied != agreedTermsHash) revert TermsMismatch(agreedTermsHash, supplied);

        if (tradeStatus == TradeStatus.Cancelled) ++_replacementCount;
        id = tradeId();
        tradeInception = _tradeCommitment(id, issuer, buyer, tradeData, position, paymentAmount, initialSettlementData);
        _setTradeStatus(TradeStatus.Incepted);
        emit TradeIncepted(issuer, buyer, id, tradeData, position, paymentAmount, initialSettlementData);
    }

    /**
     * @inheritdoc ISDCTrade
     * @dev Buyer-authorized acceptance repeats the issuer's original signed amounts.
     */
    function confirmTrade(
        string memory tradeId_, address inceptor, address counterparty, string memory tradeData,
        int256 position, int256 paymentAmount, string memory initialSettlementData
    ) external override inTradeStatus(TradeStatus.Incepted) nonReentrant {
        _requireTradeAuthorization(buyer);
        _requireTradeTerms(tradeId_, inceptor, counterparty, tradeData, position, paymentAmount, initialSettlementData);

        confirmedAt = uint64(block.timestamp);
        _exchange = AssetExchange(issuer, buyer, uint256(paymentAmount));
        _setTradeStatus(TradeStatus.Confirmed);
        emit TradeConfirmed(buyer, tradeId());
    }

    /**
     * @inheritdoc ISDCTrade
     * @dev The issuer or its operator withdraws the exact pending offer, permanently closing its ID.
     */
    function cancelTrade(
        string memory tradeId_, address inceptor, address counterparty, string memory tradeData,
        int256 position, int256 paymentAmount, string memory initialSettlementData
    ) external override inTradeStatus(TradeStatus.Incepted) {
        _requireTradeAuthorization(issuer);
        _requireTradeTerms(tradeId_, inceptor, counterparty, tradeData, position, paymentAmount, initialSettlementData);
        _setTradeStatus(TradeStatus.Cancelled);
        emit TradeCanceled(issuer, tradeId());
    }

    function _requireTradeEconomics(
        address inceptor, address counterparty, int256 position, int256 paymentAmount
    ) private view {
        if (inceptor != issuer) revert InvalidCounterparty(inceptor);
        if (counterparty != buyer) revert InvalidCounterparty(counterparty);
        uint256 payment = settlementAmount();
        if (initialAggregateAmount > uint256(type(int256).max) || payment > uint256(type(int256).max)
            || position != -int256(initialAggregateAmount) || paymentAmount != int256(payment)) revert InvalidAmount();
    }

    function _requireTradeTerms(
        string memory tradeId_, address inceptor, address counterparty, string memory tradeData,
        int256 position, int256 paymentAmount, string memory initialSettlementData
    ) private view {
        _requireTradeEconomics(inceptor, counterparty, position, paymentAmount);
        bytes32 supplied = _tradeCommitment(tradeId_, inceptor, counterparty, tradeData,
            position, paymentAmount, initialSettlementData);
        if (supplied != tradeInception) revert TermsMismatch(tradeInception, supplied);
    }

    function _tradeCommitment(
        string memory tradeId_, address inceptor, address counterparty, string memory tradeData,
        int256 position, int256 paymentAmount, string memory initialSettlementData
    ) private pure returns (bytes32) {
        return keccak256(abi.encode(tradeId_, inceptor, counterparty, tradeData, position, paymentAmount, initialSettlementData));
    }

    /**
     * @inheritdoc ISDCTrade
     * @dev Proposes contractual maturity repayment after delivery. The issuer supplies
     *      its negative repayment amount; buyer confirmation repeats that same amount.
     */
    function requestTradeTermination(
        string memory tradeId_, address requestingParty, int256 terminationPayment, string memory terminationTerms
    ) external override {
        _requireTradeAuthorization(issuer);
        _requireRequestingIssuer(requestingParty);
        if (positionState != PositionState.Outstanding) revert InvalidPositionState(positionState);
        if (block.timestamp < maturityDate) revert NotMatured(maturityDate);
        if (_isSettlementActive()) revert SettlementActive();
        if (terminationPayment != -_redemptionValue()) revert InvalidAmount();
        redemptionProposal = _redemptionCommitment(tradeId_, requestingParty, terminationPayment, terminationTerms);
        _recordPosition(PositionState.RedemptionOffered);
        emit TradeTerminationRequest(issuer, tradeId_, terminationPayment, terminationTerms);
    }

    /**
     * @inheritdoc ISDCTrade
     * @dev Buyer-authorized acceptance creates the explicit return exchange: buyer
     *      delivers units, issuer delivers the cash stated in its original proposal.
     */
    function confirmTradeTermination(
        string memory tradeId_, address requestingParty, int256 terminationPayment, string memory terminationTerms
    ) external override {
        _requireTradeAuthorization(buyer);
        _requireRequestingIssuer(requestingParty);
        if (positionState != PositionState.RedemptionOffered) revert InvalidPositionState(positionState);
        if (block.timestamp < maturityDate) revert NotMatured(maturityDate);
        _requireRedemptionTerms(tradeId_, requestingParty, terminationPayment, terminationTerms);
        _exchange = AssetExchange(buyer, issuer, uint256(-terminationPayment));
        _recordPosition(PositionState.ReturnAuthorized);
        emit TradeTerminationConfirmed(buyer, tradeId_, terminationPayment, terminationTerms);
    }

    /**
     * @inheritdoc ISDCTrade
     * @dev The requesting issuer or its operator may withdraw before a live asset
     *      attempt, including after a failed attempt. Every argument repeats the proposal.
     */
    function cancelTradeTermination(
        string memory tradeId_, address requestingParty, int256 terminationPayment, string memory terminationTerms
    ) external override {
        _requireTradeAuthorization(issuer);
        _requireRequestingIssuer(requestingParty);
        if (positionState != PositionState.RedemptionOffered && positionState != PositionState.ReturnAuthorized) {
            revert InvalidPositionState(positionState);
        }
        if (_isSettlementActive()) revert SettlementActive();
        _requireRedemptionTerms(tradeId_, requestingParty, terminationPayment, terminationTerms);
        delete redemptionProposal;
        _recordPosition(PositionState.Outstanding);
        emit TradeTerminationCanceled(issuer, tradeId_, terminationTerms);
    }

    function _requireRequestingIssuer(address requestingParty) private view {
        if (requestingParty != issuer) revert InvalidCounterparty(requestingParty);
    }

    function _requireRedemptionTerms(
        string memory id, address requestingParty, int256 amount, string memory terms
    ) private view {
        if (amount != -_redemptionValue()) revert InvalidAmount();
        if (_redemptionCommitment(id, requestingParty, amount, terms) != redemptionProposal) {
            revert RedemptionProposalMismatch();
        }
    }

    /// @dev Bounds the signed ERC-6123 amount and binds acceptance to this trade's economics.
    function _redemptionValue() private view returns (int256) {
        uint256 value = finalRedemptionAmount();
        if (value > uint256(type(int256).max)) revert InvalidAmount();
        return int256(value);
    }

    function _redemptionCommitment(
        string memory id, address requestingParty, int256 amount, string memory terms
    ) private view returns (bytes32) {
        if (keccak256(bytes(id)) != keccak256(bytes(tradeId()))) revert InvalidTradeData();
        return keccak256(abi.encode(id, requestingParty, amount, agreedTermsHash, terms));
    }

    // ------------------------------ Coupon Payment ------------------------------ */

    /**
     * @notice Buyer locks the due coupon claim against a generated-key payment from the issuer.
     * @dev The bond is the ERC-7573 callback. It freezes both outcome hashes when generation
     *      completes and marks the coupon paid only after independently verifying the released
     *      success key in {transferWithKey}.
     */
    function payCoupon(
        uint256 index,
        bytes calldata transaction,
        address expectedGenerationOracle
    ) external onlyBuyer nonReentrant {
        if (positionState == PositionState.Undelivered) revert InvalidPositionState(positionState);
        _touchState();
        FixedRateBondLib.inceptCouponPayment(
            couponPeriods,
            _couponSettlements[index],
            _couponIndexByPaymentId,
            index,
            transaction,
            CouponPaymentInception({
                calculationAmount: specifiedDenomination,
                unitCount: assetTokenAmount(),
                rate: interestRate,
                frequency: couponsPerYear,
                scale: rateScale,
                expectedGenerationOracle: expectedGenerationOracle,
                paymentContract: paymentContract,
                payer: issuer,
                payee: buyer
            })
        );
    }

    /** @notice Stable coupon id in a domain disjoint from issuance and redemption asset legs. */
    function couponPaymentRequestId(uint256 index) external view returns (bytes32) {
        if (index >= couponPeriods.length) revert InvalidCouponPeriod(index);
        return bytes32(
            ((uint256(uint160(address(this))) << 96) ^ COUPON_ID_DOMAIN) | uint96(index + 1)
        );
    }

    function couponPaymentStatus(uint256 index) external view returns (CouponPaymentStatus) {
        return _couponSettlements[index].status;
    }

    /** @dev Dispatches coupon ids to their logical claim lock; all other ids use the asset lock. */
    function onInceptionCompleted(uint256 id) public override returns (bytes4) {
        if (msg.sender != paymentContract) revert NotDemoPaymentContract(msg.sender);
        uint256 indexPlusOne = _couponIndexPlusOne(id);
        if (indexPlusOne == 0) return super.onInceptionCompleted(id);
        uint256 index = indexPlusOne - 1;
        _touchState();
        FixedRateBondLib.completeCouponLock(
            _couponSettlements[index], index, id, paymentContract, issuer, buyer
        );
        return IDecryptionContractInceptionCallback.onInceptionCompleted.selector;
    }

    /// @dev The local payment adapter moves cash and releases the outcome atomically.
    ///      Direct key submission would let a pending settlement be front-run without payment.
    function transferWithKey(uint256 id, bytes memory key) public override {
        if (msg.sender != paymentContract) revert NotDemoPaymentContract(msg.sender);
        uint256 indexPlusOne = _couponIndexPlusOne(id);
        if (indexPlusOne == 0) {
            super.transferWithKey(id, key);
            return;
        }
        uint256 index = indexPlusOne - 1;
        _touchState();
        FixedRateBondLib.transferCouponWithKey(_couponSettlements[index], index, id, key);
    }

    function _couponIndexPlusOne(uint256 id) private view returns (uint256 indexPlusOne) {
        return _couponIndexByPaymentId[id];
    }

    // ------------------------------ Economics ------------------------------ */

    /**
     * @notice Returns the coupon amount payable for a period.
     * @dev ACT/ACT ICMA is calculated and rounded down per calculation amount, which equals
     *      specifiedDenomination. Multiply that coupon by the number of tradable units only
     *      after rounding, including for a short first period. Amounts use amountScale.
     * @param index Zero-based index of the coupon period.
     */
    function couponAmount(uint256 index) public view returns (uint256) {
        return _couponAmountPerUnit(index) * assetTokenAmount();
    }

    /// @dev The library computes one unit's coupon independently of the bond's position size.
    function _couponAmountPerUnit(uint256 index) private view returns (uint256) {
        return FixedRateBondLib.couponAmount(couponPeriods[index], specifiedDenomination, interestRate, couponsPerYear, rateScale);
    }

    /// @notice Returns the number of coupon periods.
    function couponPeriodCount() external view returns (uint256) {
        return couponPeriods.length;
    }

    /// @notice Returns all coupon periods.
    function allCouponPeriods() external view returns (CouponPeriod[] memory) {
        return couponPeriods;
    }

    /// @notice Returns the cash amount payable by the buyer at settlement.
    function settlementAmount() public view returns (uint256) {
        return FixedRateBondLib.bondPercentageAmount(false);
    }

    /// @notice Returns the amount repaid at maturity.
    function finalRedemptionAmount() public view returns (uint256) {
        return FixedRateBondLib.bondPercentageAmount(true);
    }

    /// @notice Unadjusted start of the first interest accrual period.
    function interestCommencementDate() external view returns (uint64) {
        return couponPeriods[0].startDate;
    }

    /// @notice ICMA document status, issued once initial delivery against payment completes.
    /// @dev Remains ISSUED through settlement and redemption; no separate mutable status.
    function documentStatus() external view returns (string memory) {
        return FixedRateBondLib.documentStatus(positionState != PositionState.Undelivered);
    }

    /// @notice ICMA document identity for this chain, bond and represented-state revision.
    /// @dev Reverts when the complete revision is unavailable; a partial revision is not an ID.
    function documentId() external view returns (string memory) {
        return ProductLib.documentId(stateVersion());
    }

    /// @notice ICMA payment-frequency label, with ATMATURITY for a single final coupon.
    function interestPaymentFrequency() external view returns (string memory) {
        return FixedRateBondLib.interestPaymentFrequency(couponPeriods.length, couponsPerYear);
    }

    /// @notice Following payment dates and ACT/ACT ICMA amounts per specified denomination.
    /// @dev Each amount is rounded down to amountScale before multiplication by the unit count.
    ///      couponAmount(index) equals this schedule's amount times assetTokenAmount().
    function couponSchedule() external view returns (CouponPayment[] memory) {
        CouponPayment[] memory payments = new CouponPayment[](couponPeriods.length);
        for (uint256 i; i < payments.length; ++i) {
            CouponPayment memory payment = payments[i];
            payment.paymentDate = couponPeriods[i].paymentDate;
            payment.amount = _couponAmountPerUnit(i);
        }
        return payments;
    }

    /// @notice Monotonic revision of stored bond state and versioned payment-oracle configuration.
    /// @dev Supports configurable finalized resource templates without pinning their contents.
    ///      Live token diagnostics are not versioned XML bindings. Unversioned dependencies
    ///      revert; exact-block rendering then requires templates without revision-dependent
    ///      bindings such as documentId(). This is not termsHash.
    function stateVersion() public view override returns (uint256) {
        return FixedRateBondLib.representedStateVersion(_localStateVersion);
    }

    /// @notice Current configured issuer oracle, not a frozen DvP leg's generation oracle.
    function issuerPaymentOracle() external view returns (address) {
        return _paymentOracle(issuer);
    }

    /// @notice Current configured buyer oracle; original parties do not reverse at redemption.
    function buyerPaymentOracle() external view returns (address) {
        return _paymentOracle(buyer);
    }

    function _paymentOracle(address participant) private view returns (address) {
        return IPaymentOracleConfiguration(paymentContract).oracleOf(participant);
    }

    // ------------------------------ Terms ------------------------------ */

    /// @notice Current offer commitment to economics, legal manifest content and settlement contracts. Zero before inception.
    function termsHash() public view returns (bytes32) {
        return agreedTermsHash;
    }

    /// @notice Returns the current offer ID. The first ID is the bond address, available before inception.
    /// @dev Replacement offers append their sequence number, starting with 2.
    function tradeId() public view returns (string memory) {
        string memory firstId = ProductLib.tradeId(address(this));
        if (_replacementCount == 0) return firstId;
        return string.concat(firstId, "-", Strings.toString(_replacementCount + 1));
    }

    // ------------------------------ ERC-7573 asset leg ------------------------------ */

    // These hooks implement the local demo adapter's public exchange context. The context
    // is written only when the appropriate counterparty accepts agreement or redemption.
    function _dvpSeller() internal view override returns (address) {
        return _exchange.deliverer;
    }

    function _dvpBuyer() internal view override returns (address) {
        return _exchange.receiver;
    }

    function _dvpAssetAmount() internal view override returns (uint256) {
        return assetTokenAmount();
    }

    /**
     * @notice Number of security-token units representing the aggregate nominal amount.
     * @dev The supported ICMA terms define one token per specified denomination. The deployment
     *      validation guarantees that specifiedDenomination is positive and divides the aggregate
     *      exactly, so no rounding is possible here.
     */
    function assetTokenAmount() public view returns (uint256) {
        return initialAggregateAmount / specifiedDenomination;
    }

    /// @inheritdoc DemoAssetLocking
    function _dvpAssetToken() internal view override returns (address) {
        return assetToken;
    }

    /// @inheritdoc DemoAssetLocking
    function _dvpPaymentAmount() internal view override returns (uint256) {
        return _exchange.cashAmount;
    }

    /// @inheritdoc DemoAssetLocking
    function _dvpPaymentContract() internal view override returns (address) {
        return paymentContract;
    }

    /// @dev A confirmed agreement permits its first delivery. Later exchanges require
    ///      accepted repayment terms; outstanding or repaid positions cannot be delivered again.
    function _requireDvpReady() internal view override {
        if (tradeStatus != TradeStatus.Confirmed) revert InvalidTradeStatus(tradeStatus);
        if (positionState != PositionState.Undelivered && positionState != PositionState.ReturnAuthorized) {
            revert InvalidPositionState(positionState);
        }
    }

    /// @dev The adapter has already released the asset against authenticated payment.
    function _onAssetClaimed() internal override {
        if (positionState == PositionState.Undelivered) {
            _recordPosition(PositionState.Outstanding);
            emit TradeActivated(tradeId());
        } else {
            delete redemptionProposal;
            _recordPosition(PositionState.Repaid);
            emit TradeTerminated(tradeId(), "contractual maturity repayment");
        }
    }

    /// @dev Reclamation changes no agreement or position; the adapter emits TokenReclaimed.
    function _onAssetReclaimed() internal override {}

    function _recordPosition(PositionState next) private {
        positionState = next;
        _touchState();
        emit PositionUpdated(next);
    }

    // ------------------------------ Internal ------------------------------ */

    function _setTradeStatus(TradeStatus newStatus) private {
        TradeStatus previous = tradeStatus;
        tradeStatus = newStatus;
        _touchState();
        emit TradeStatusChanged(previous, newStatus);
    }

    /// @dev Called before external interactions where possible; a reverted operation rolls it back.
    function _touchState() internal override {
        ++_localStateVersion;
    }

    // ------------------------------ XML View ------------------------------ */

    /// @inheritdoc AbstractProduct
    function _productType() internal pure override returns (string memory name, string memory version) {
        return ("FixedRateBond", "1.0.0");
    }
}
