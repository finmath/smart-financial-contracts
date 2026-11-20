// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import {TradeAuthorizable} from "@finmath.net/sdc/contracts/TradeAuthorizable.sol";
import {FxSpotTrade} from "../contracts/FxSpotTrade.sol";
import {FxSpotTradeFactory} from "../contracts/FxSpotTradeFactory.sol";
import {ERC20TokenExample} from "../contracts/ERC20TokenExample.sol";
import {
    IERC20RouterToken,
    IPvPSettlement,
    ERC20PvPSettlementRouter
} from "../contracts/ERC20PvPSettlementRouter.sol";
import {Vm, ReturnToken, ReentrantCounterparty} from "./TestSupport.sol";

contract FxSpotTradeTest {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    address private constant PARTY_A = address(0xA);
    address private constant PARTY_B = address(0xB);
    address private constant OUTSIDER = address(0xC);
    uint256 private constant INITIAL_BALANCE = 1_000;
    int256 private constant POSITION = 100;
    int256 private constant PAYMENT = -200;

    FxSpotTradeFactory private factory;
    ERC20PvPSettlementRouter private router;
    ERC20TokenExample private base;
    ERC20TokenExample private quote;
    FxSpotTrade private trade;

    event TradeIncepted(
        address indexed initiator,
        address indexed withParty,
        string tradeId,
        string tradeData,
        int256 position,
        int256 paymentAmount,
        string initialSettlementData
    );
    event TradeConfirmed(address indexed confirmer, string tradeId);
    event TradeTerminated(string tradeId, string cause);
    event TradeCanceled(address indexed initiator, string tradeId);

    function setUp() public {
        factory = new FxSpotTradeFactory();
        router = factory.settlementRouter();
        base = new ERC20TokenExample("Base", "BASE", 18);
        quote = new ERC20TokenExample("Quote", "QUOTE", 6);
        trade = _createTrade(_token(base), _token(quote), PARTY_A, PARTY_B);
        _fundAndApprove(base, PARTY_A);
        _fundAndApprove(base, PARTY_B);
        _fundAndApprove(quote, PARTY_A);
        _fundAndApprove(quote, PARTY_B);
    }

    function testFactoryRegistersFixedConfiguration() public view {
        require(router.factory() == address(factory), "router factory");
        require(router.registeredTrade(address(trade)), "not registered");
        require(trade.phase() == FxSpotTrade.Phase.Created, "phase");
        require(trade.partyA() == PARTY_A && trade.partyB() == PARTY_B, "parties");
        require(address(trade.baseToken()) == address(base), "base token");
        require(address(trade.quoteToken()) == address(quote), "quote token");
        require(address(trade.settlementRouter()) == address(router), "router");
        require(bytes(trade.tradeId()).length == 0, "unexpected trade id");
    }

    function testFactoryEmitsTradeCreatedWithCreatedAddressAndOriginalFieldOrder() public {
        vm.recordLogs();
        FxSpotTrade created = _createTrade(_token(base), _token(quote), PARTY_A, PARTY_B);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        require(logs.length == 1 && logs[0].emitter == address(factory), "factory event");
        require(logs[0].topics.length == 4, "indexed fields");
        require(
            logs[0].topics[0]
                == keccak256("TradeCreated(address,address,address,address,address,address)"),
            "event signature"
        );
        require(logs[0].topics[1] == bytes32(uint256(uint160(address(created)))), "trade address");
        require(logs[0].topics[2] == bytes32(uint256(uint160(PARTY_A))), "creator");
        require(logs[0].topics[3] == bytes32(uint256(uint160(address(base)))), "base token");
        (address quoteToken, address partyA, address partyB) =
            abi.decode(logs[0].data, (address, address, address));
        require(quoteToken == address(quote) && partyA == PARTY_A && partyB == PARTY_B, "event data");
    }

    function testXmlUsesSmartFinancialProductEnvelope() public view {
        bytes memory xml = bytes(trade.stateXmlTemplate());
        bytes memory prefix = bytes(
            '<?xml version="1.0" encoding="UTF-8"?>\n<SmartFinancialProduct xmlns="urn:smart-product-framework:financial-product:1.0"'
        );
        bytes memory suffix = bytes("</SmartFinancialProduct>\n");
        require(xml.length >= prefix.length + suffix.length, "XML length");
        for (uint256 i; i < prefix.length; ++i) {
            require(xml[i] == prefix[i], "XML root and namespace");
        }
        for (uint256 i; i < suffix.length; ++i) {
            require(xml[xml.length - suffix.length + i] == suffix[i], "XML closing root");
        }
    }

    function testInceptionStoresExactTermsAndEmitsEvent() public {
        vm.expectEmit(true, true, false, true, address(trade));
        emit TradeIncepted(PARTY_A, PARTY_B, "1", "terms", POSITION, PAYMENT, "settlement");
        _incept();
        require(trade.phase() == FxSpotTrade.Phase.Incepted, "phase");
        require(trade.inceptor() == PARTY_A, "inceptor");
        require(trade.position() == POSITION && trade.paymentAmount() == PAYMENT, "amounts");
        require(keccak256(bytes(trade.tradeData())) == keccak256("terms"), "trade data");
        require(keccak256(bytes(trade.initialSettlementData())) == keccak256("settlement"), "data");
        _assertOriginalBalancesAndAllowances();
    }

    function testConfirmationSettlesExactlyAndEmitsTerminalEvents() public {
        _incept();
        vm.expectEmit(true, false, false, true, address(trade));
        emit TradeConfirmed(PARTY_B, "1");
        vm.expectEmit(false, false, false, true, address(trade));
        emit TradeTerminated("1", "atomic settlement completed");
        _confirm();
        _assertSettled();
    }

    function testFuzzDirectAndDelegatedBothInceptorsAndDirections(
        bool delegated,
        bool bIncepts,
        bool receivesBase,
        uint128 baseAmountSeed,
        uint128 quoteAmountSeed
    ) public {
        // uint128 inputs leave ample room for signed conversion and initial balances.
        uint256 baseAmount = uint256(baseAmountSeed) + 1;
        uint256 quoteAmount = uint256(quoteAmountSeed) + 1;
        address inceptor = bIncepts ? PARTY_B : PARTY_A;
        address confirmer = bIncepts ? PARTY_A : PARTY_B;
        address basePayer = receivesBase ? confirmer : inceptor;
        address baseReceiver = receivesBase ? inceptor : confirmer;
        base.mint(basePayer, baseAmount);
        quote.mint(baseReceiver, quoteAmount);
        vm.prank(basePayer);
        base.approve(address(router), baseAmount);
        vm.prank(baseReceiver);
        quote.approve(address(router), quoteAmount);
        int256 position = receivesBase ? int256(baseAmount) : -int256(baseAmount);
        int256 payment = receivesBase ? -int256(quoteAmount) : int256(quoteAmount);

        if (delegated) {
            vm.prank(inceptor);
            trade.setTradeOperator(OUTSIDER, true);
            vm.prank(confirmer);
            trade.setTradeOperator(OUTSIDER, true);
        }
        vm.prank(delegated ? OUTSIDER : inceptor);
        trade.inceptTrade(inceptor, confirmer, "terms", position, payment, "settlement");
        vm.prank(delegated ? OUTSIDER : confirmer);
        trade.confirmTrade("1", inceptor, confirmer, "terms", position, payment, "settlement");

        require(trade.phase() == FxSpotTrade.Phase.Settled, "phase");
        require(router.consumedTrade(address(trade), keccak256("1")), "authorization");
        require(base.balanceOf(basePayer) == INITIAL_BALANCE, "base paid");
        require(base.balanceOf(baseReceiver) == INITIAL_BALANCE + baseAmount, "base received");
        require(quote.balanceOf(baseReceiver) == INITIAL_BALANCE, "quote paid");
        require(quote.balanceOf(basePayer) == INITIAL_BALANCE + quoteAmount, "quote received");
        require(base.allowance(basePayer, address(router)) == 0, "base allowance");
        require(quote.allowance(baseReceiver, address(router)) == 0, "quote allowance");
    }

    function testDelegatedTradeEmitsParticipantsAndPaysOnlyParticipants() public {
        address confirmationOperator = address(0xD);
        vm.prank(PARTY_A);
        trade.setTradeOperator(OUTSIDER, true);
        vm.prank(PARTY_B);
        trade.setTradeOperator(confirmationOperator, true);

        vm.expectEmit(true, true, false, true, address(trade));
        emit TradeIncepted(PARTY_A, PARTY_B, "1", "terms", POSITION, PAYMENT, "settlement");
        vm.prank(OUTSIDER);
        trade.inceptTrade(PARTY_A, PARTY_B, "terms", POSITION, PAYMENT, "settlement");
        require(trade.inceptor() == PARTY_A, "operator became inceptor");
        vm.expectEmit(true, false, false, true, address(trade));
        emit TradeConfirmed(PARTY_B, "1");
        vm.prank(confirmationOperator);
        trade.confirmTrade("1", PARTY_A, PARTY_B, "terms", POSITION, PAYMENT, "settlement");
        _assertSettled();
        require(
            base.balanceOf(OUTSIDER) == 0 && quote.balanceOf(OUTSIDER) == 0,
            "inceptor operator received tokens"
        );
        require(
            base.balanceOf(confirmationOperator) == 0 && quote.balanceOf(confirmationOperator) == 0,
            "confirmation operator received tokens"
        );
        vm.expectRevert(FxSpotTrade.InvalidPhase.selector);
        vm.prank(confirmationOperator);
        trade.confirmTrade("1", PARTY_A, PARTY_B, "terms", POSITION, PAYMENT, "settlement");
    }

    function testDelegatedCancellationConsumesTradeAndEmitsInceptor() public {
        _incept();
        vm.prank(PARTY_A);
        trade.setTradeOperator(OUTSIDER, true);
        vm.expectEmit(true, false, false, true, address(trade));
        emit TradeCanceled(PARTY_A, "1");
        vm.prank(OUTSIDER);
        trade.cancelTrade("1", PARTY_A, PARTY_B, "terms", POSITION, PAYMENT, "settlement");
        require(trade.phase() == FxSpotTrade.Phase.Canceled, "phase");
        require(
            router.consumedTrade(address(trade), keccak256("1")),
            "authorization survived cancellation"
        );
        _assertOriginalBalancesAndAllowances();
        _assertTerminalCallsRevert();
    }

    function testConfirmationOperatorRequiresCounterpartyApprovalDespiteAllowances() public {
        vm.prank(PARTY_A);
        trade.setTradeOperator(OUTSIDER, true);
        vm.prank(OUTSIDER);
        trade.inceptTrade(PARTY_A, PARTY_B, "terms", POSITION, PAYMENT, "settlement");
        // Inceptor authorization and both standing token allowances do not grant B's consent.
        _expectUnauthorized(OUTSIDER, PARTY_B);
        vm.prank(OUTSIDER);
        trade.confirmTrade("1", PARTY_A, PARTY_B, "terms", POSITION, PAYMENT, "settlement");
        vm.prank(OUTSIDER);
        trade.setTradeOperator(address(0xD), true);
        require(!trade.isTradeOperator(PARTY_B, address(0xD)), "delegation escaped grantor");
        _expectUnauthorized(address(0xD), PARTY_B);
        vm.prank(address(0xD));
        trade.confirmTrade("1", PARTY_A, PARTY_B, "terms", POSITION, PAYMENT, "settlement");
        _assertOpenAndUnspent();
    }

    function testRevokedOperatorCannotConfirmAndCanBeReauthorized() public {
        _incept();
        vm.prank(PARTY_B);
        trade.setTradeOperator(OUTSIDER, true);
        vm.prank(PARTY_B);
        trade.setTradeOperator(OUTSIDER, false);
        _expectUnauthorized(OUTSIDER, PARTY_B);
        vm.prank(OUTSIDER);
        trade.confirmTrade("1", PARTY_A, PARTY_B, "terms", POSITION, PAYMENT, "settlement");
        _assertOpenAndUnspent();
        vm.prank(PARTY_B);
        trade.setTradeOperator(OUTSIDER, true);
        vm.prank(OUTSIDER);
        trade.confirmTrade("1", PARTY_A, PARTY_B, "terms", POSITION, PAYMENT, "settlement");
        _assertSettled();
    }

    function testOperatorApprovalIsScopedToOneTrade() public {
        FxSpotTrade second = _createTrade(_token(base), _token(quote), PARTY_A, PARTY_B);
        vm.prank(PARTY_A);
        trade.setTradeOperator(OUTSIDER, true);
        require(!second.isTradeOperator(PARTY_A, OUTSIDER), "approval leaked to another trade");
        _expectUnauthorized(OUTSIDER, PARTY_A);
        vm.prank(OUTSIDER);
        second.inceptTrade(PARTY_A, PARTY_B, "terms", POSITION, PAYMENT, "settlement");
        require(second.phase() == FxSpotTrade.Phase.Created, "unauthorized inception");
        _assertOriginalBalancesAndAllowances();
    }

    function testDelegatedConfirmationRejectsLegacySignsAndRedirectedParticipants() public {
        _incept();
        vm.prank(PARTY_B);
        trade.setTradeOperator(OUTSIDER, true);
        vm.expectRevert(FxSpotTrade.TermsMismatch.selector);
        vm.prank(OUTSIDER);
        trade.confirmTrade("1", PARTY_A, PARTY_B, "terms", -POSITION, -PAYMENT, "settlement");
        vm.expectRevert(FxSpotTrade.InvalidParty.selector);
        vm.prank(OUTSIDER);
        trade.confirmTrade("1", PARTY_A, OUTSIDER, "terms", POSITION, PAYMENT, "settlement");
        _assertOpenAndUnspent();
    }

    function testCancellationConsumesTradeWithoutSpending() public {
        _incept();
        vm.expectEmit(true, false, false, true, address(trade));
        emit TradeCanceled(PARTY_A, "1");
        _cancel();
        require(trade.phase() == FxSpotTrade.Phase.Canceled, "phase");
        require(
            router.consumedTrade(address(trade), keccak256("1")),
            "authorization survives cancellation"
        );
        require(trade.position() == POSITION && trade.paymentAmount() == PAYMENT, "lost terms");
        _assertOriginalBalancesAndAllowances();
        _assertTerminalCallsRevert();
    }

    function testPartyBCanInceptAndCancel() public {
        vm.prank(PARTY_B);
        trade.inceptTrade(PARTY_B, PARTY_A, "terms", -POSITION, -PAYMENT, "settlement");
        vm.prank(PARTY_B);
        trade.cancelTrade("1", PARTY_B, PARTY_A, "terms", -POSITION, -PAYMENT, "settlement");
        require(trade.phase() == FxSpotTrade.Phase.Canceled, "phase");
        require(router.consumedTrade(address(trade), keccak256("1")), "authorization");
        _assertOriginalBalancesAndAllowances();
    }

    function testRouterRejectionRollsBackCancellationPhase() public {
        // Direct deployment deliberately omits the factory's router registration.
        FxSpotTrade unregistered =
            new FxSpotTrade(_token(base), _token(quote), PARTY_A, PARTY_B, router);
        vm.prank(PARTY_A);
        unregistered.inceptTrade(PARTY_A, PARTY_B, "terms", POSITION, PAYMENT, "settlement");
        vm.expectRevert(ERC20PvPSettlementRouter.UnregisteredTrade.selector);
        vm.prank(PARTY_A);
        unregistered.cancelTrade("1", PARTY_A, PARTY_B, "terms", POSITION, PAYMENT, "settlement");
        require(
            unregistered.phase() == FxSpotTrade.Phase.Incepted,
            "cancellation phase survived revert"
        );
        require(
            !router.consumedTrade(address(trade), keccak256("1")), "unrelated authorization changed"
        );
        _assertOriginalBalancesAndAllowances();
    }

    function testSettlementPreventsCancellationAndReplay() public {
        _incept();
        _confirm();
        _assertTerminalCallsRevert();
        _assertSettled();
    }

    function testSeparateTradesUseIndependentAuthorizations() public {
        FxSpotTrade second = _createTrade(_token(base), _token(quote), PARTY_B, PARTY_A);
        _incept();
        _cancel();
        require(
            !router.consumedTrade(address(second), keccak256("1")),
            "cancellation affected another trade"
        );
        vm.prank(PARTY_A);
        second.inceptTrade(PARTY_A, PARTY_B, "new terms", POSITION, PAYMENT, "settlement");
        vm.prank(PARTY_B);
        second.confirmTrade("1", PARTY_A, PARTY_B, "new terms", POSITION, PAYMENT, "settlement");
        require(second.phase() == FxSpotTrade.Phase.Settled, "second trade did not settle");
        require(router.consumedTrade(address(second), keccak256("1")), "second authorization");
        require(trade.phase() == FxSpotTrade.Phase.Canceled, "first trade changed");
    }

    function testOnlyNamedPartyCanCreateTrade() public {
        vm.expectRevert(FxSpotTradeFactory.CreatorNotParty.selector);
        vm.prank(OUTSIDER);
        factory.createTrade(_token(base), _token(quote), PARTY_A, PARTY_B);
    }

    function testConstructorRejectsInvalidTokensPartiesAndRouter() public {
        vm.expectRevert(FxSpotTrade.InvalidToken.selector);
        new FxSpotTrade(IERC20RouterToken(address(0)), _token(quote), PARTY_A, PARTY_B, router);
        vm.expectRevert(FxSpotTrade.InvalidToken.selector);
        new FxSpotTrade(_token(base), _token(base), PARTY_A, PARTY_B, router);
        vm.expectRevert(FxSpotTrade.InvalidToken.selector);
        new FxSpotTrade(_token(base), IERC20RouterToken(OUTSIDER), PARTY_A, PARTY_B, router);
        vm.expectRevert(FxSpotTrade.InvalidParty.selector);
        new FxSpotTrade(_token(base), _token(quote), PARTY_A, address(0), router);
        vm.expectRevert(FxSpotTrade.InvalidParty.selector);
        new FxSpotTrade(_token(base), _token(quote), PARTY_A, PARTY_A, router);
        vm.expectRevert(FxSpotTrade.InvalidRouter.selector);
        new FxSpotTrade(
            _token(base), _token(quote), PARTY_A, PARTY_B, IPvPSettlement(OUTSIDER)
        );
        vm.expectRevert(ERC20PvPSettlementRouter.InvalidFactory.selector);
        new ERC20PvPSettlementRouter(address(0));
    }

    function testRouterRejectsUnregisteredCallersAndUnauthorizedRegistration() public {
        vm.expectRevert(ERC20PvPSettlementRouter.NotFactory.selector);
        router.registerTrade(address(trade));
        vm.expectRevert(ERC20PvPSettlementRouter.UnregisteredTrade.selector);
        router.settlePvP(
            "1", _token(base), _token(quote), PARTY_A, PARTY_B, POSITION, PAYMENT
        );
        vm.expectRevert(ERC20PvPSettlementRouter.UnregisteredTrade.selector);
        router.cancelPvP("1");
        require(
            !router.consumedTrade(address(trade), keccak256("1")), "outsider changed authorization"
        );
        _assertOriginalBalancesAndAllowances();
    }

    function testRouterRejectsInvalidAndDuplicateRegistration() public {
        vm.expectRevert(ERC20PvPSettlementRouter.InvalidTrade.selector);
        vm.prank(address(factory));
        router.registerTrade(OUTSIDER);
        vm.expectRevert(ERC20PvPSettlementRouter.InvalidTrade.selector);
        vm.prank(address(factory));
        router.registerTrade(address(trade));
    }

    function testInceptionRejectsWrongPartiesAndRepeatedInception() public {
        _expectUnauthorized(OUTSIDER, PARTY_A);
        vm.prank(OUTSIDER);
        trade.inceptTrade(PARTY_A, PARTY_B, "terms", POSITION, PAYMENT, "settlement");
        vm.expectRevert(FxSpotTrade.InvalidParty.selector);
        vm.prank(PARTY_A);
        trade.inceptTrade(PARTY_A, OUTSIDER, "terms", POSITION, PAYMENT, "settlement");
        vm.expectRevert(FxSpotTrade.InvalidParty.selector);
        vm.prank(OUTSIDER);
        trade.inceptTrade(OUTSIDER, PARTY_B, "terms", POSITION, PAYMENT, "settlement");
        _incept();
        vm.expectRevert(FxSpotTrade.InvalidPhase.selector);
        _incept();
    }

    function testInceptionRejectsZeroEqualSignsAndMinimumInteger() public {
        int256[6] memory positions =
            [int256(0), int256(100), int256(100), int256(-100), type(int256).min, int256(100)];
        int256[6] memory payments =
            [int256(-200), int256(0), int256(200), int256(-200), int256(200), type(int256).min];
        for (uint256 i; i < positions.length; i++) {
            vm.expectRevert(FxSpotTrade.InvalidLegs.selector);
            vm.prank(PARTY_A);
            trade.inceptTrade(PARTY_A, PARTY_B, "terms", positions[i], payments[i], "settlement");
        }
        require(trade.phase() == FxSpotTrade.Phase.Created, "failed inception changed phase");
        require(keccak256(bytes(_incept())) == keccak256("1"), "failed inception consumed id");
    }

    function testConfirmAndCancelRequireInception() public {
        vm.expectRevert(FxSpotTrade.InvalidPhase.selector);
        _confirm();
        vm.expectRevert(FxSpotTrade.InvalidPhase.selector);
        _cancel();
        require(!router.consumedTrade(address(trade), keccak256("1")), "authorization changed");
    }

    function testConfirmationRequiresCounterpartyAndOriginalInceptor() public {
        _incept();
        _expectUnauthorized(PARTY_A, PARTY_B);
        vm.prank(PARTY_A);
        trade.confirmTrade("1", PARTY_A, PARTY_B, "terms", POSITION, PAYMENT, "settlement");
        _expectUnauthorized(OUTSIDER, PARTY_B);
        vm.prank(OUTSIDER);
        trade.confirmTrade("1", PARTY_A, PARTY_B, "terms", POSITION, PAYMENT, "settlement");
        vm.expectRevert(FxSpotTrade.InvalidParty.selector);
        vm.prank(PARTY_B);
        trade.confirmTrade("1", OUTSIDER, PARTY_B, "terms", POSITION, PAYMENT, "settlement");
        vm.expectRevert(FxSpotTrade.InvalidParty.selector);
        vm.prank(PARTY_B);
        trade.confirmTrade("1", PARTY_A, OUTSIDER, "terms", POSITION, PAYMENT, "settlement");
        vm.expectRevert(FxSpotTrade.InvalidParty.selector);
        vm.prank(PARTY_B);
        trade.confirmTrade("1", PARTY_B, PARTY_A, "terms", POSITION, PAYMENT, "settlement");
    }

    function testConfirmationRequiresEveryTermToMatch() public {
        _incept();
        for (uint256 field; field < 4; field++) {
            vm.expectRevert(FxSpotTrade.TermsMismatch.selector);
            vm.prank(PARTY_B);
            trade.confirmTrade(
                "1",
                PARTY_A,
                PARTY_B,
                field == 0 ? "changed" : "terms",
                field == 1 ? POSITION + 1 : POSITION,
                field == 2 ? PAYMENT + 1 : PAYMENT,
                field == 3 ? "changed" : "settlement"
            );
        }
        _assertOpenAndUnspent();
    }

    function testCancellationRequiresInceptorAndEveryTermToMatch() public {
        _incept();
        _expectUnauthorized(PARTY_B, PARTY_A);
        vm.prank(PARTY_B);
        trade.cancelTrade("1", PARTY_A, PARTY_B, "terms", POSITION, PAYMENT, "settlement");
        _expectUnauthorized(OUTSIDER, PARTY_A);
        vm.prank(OUTSIDER);
        trade.cancelTrade("1", PARTY_A, PARTY_B, "terms", POSITION, PAYMENT, "settlement");
        vm.expectRevert(FxSpotTrade.InvalidParty.selector);
        vm.prank(PARTY_A);
        trade.cancelTrade("1", PARTY_A, OUTSIDER, "terms", POSITION, PAYMENT, "settlement");
        vm.expectRevert(FxSpotTrade.InvalidParty.selector);
        vm.prank(PARTY_A);
        trade.cancelTrade("1", OUTSIDER, PARTY_B, "terms", POSITION, PAYMENT, "settlement");
        for (uint256 field; field < 4; field++) {
            vm.expectRevert(FxSpotTrade.TermsMismatch.selector);
            vm.prank(PARTY_A);
            trade.cancelTrade(
                "1",
                PARTY_A,
                PARTY_B,
                field == 0 ? "changed" : "terms",
                field == 1 ? POSITION + 1 : POSITION,
                field == 2 ? PAYMENT + 1 : PAYMENT,
                field == 3 ? "changed" : "settlement"
            );
        }
        _assertOpenAndUnspent();
    }

    function testSecondLegAllowanceFailureRollsBackAndCanRetry() public {
        _incept();
        vm.prank(PARTY_A);
        quote.approve(address(router), 199);
        vm.expectRevert(
            abi.encodeWithSelector(
                ERC20PvPSettlementRouter.TransferFromFailed.selector, address(quote)
            )
        );
        _confirm();
        require(trade.phase() == FxSpotTrade.Phase.Incepted, "phase not restored");
        require(!router.consumedTrade(address(trade), keccak256("1")), "authorization not restored");
        require(base.balanceOf(PARTY_A) == INITIAL_BALANCE, "first transfer survived");
        require(base.balanceOf(PARTY_B) == INITIAL_BALANCE, "base payer balance");
        require(base.allowance(PARTY_B, address(router)) == INITIAL_BALANCE, "base allowance");
        require(quote.balanceOf(PARTY_A) == INITIAL_BALANCE, "quote payer balance");
        require(quote.balanceOf(PARTY_B) == INITIAL_BALANCE, "quote receiver balance");
        require(quote.allowance(PARTY_A, address(router)) == 199, "quote allowance");
        vm.prank(PARTY_A);
        quote.approve(address(router), INITIAL_BALANCE);
        _confirm();
        _assertSettled();
    }

    function testSecondLegBalanceFailureCanBeCanceled() public {
        _incept();
        vm.prank(PARTY_A);
        quote.transfer(OUTSIDER, INITIAL_BALANCE);
        vm.expectRevert(
            abi.encodeWithSelector(
                ERC20PvPSettlementRouter.TransferFromFailed.selector, address(quote)
            )
        );
        _confirm();
        require(base.balanceOf(PARTY_A) == INITIAL_BALANCE, "first transfer survived");
        require(base.balanceOf(PARTY_B) == INITIAL_BALANCE, "base payer balance");
        require(base.allowance(PARTY_B, address(router)) == INITIAL_BALANCE, "base allowance");
        _cancel();
        require(trade.phase() == FxSpotTrade.Phase.Canceled, "cannot cancel failed settlement");
        require(
            router.consumedTrade(address(trade), keccak256("1")),
            "authorization survives cancellation"
        );
    }

    function testFirstLegFailureLeavesQuoteUnspent() public {
        _incept();
        vm.prank(PARTY_B);
        base.approve(address(router), 0);
        vm.expectRevert(
            abi.encodeWithSelector(
                ERC20PvPSettlementRouter.TransferFromFailed.selector, address(base)
            )
        );
        _confirm();
        require(trade.phase() == FxSpotTrade.Phase.Incepted, "phase");
        require(!router.consumedTrade(address(trade), keccak256("1")), "authorization");
        require(quote.balanceOf(PARTY_A) == INITIAL_BALANCE, "quote spent");
        require(quote.balanceOf(PARTY_B) == INITIAL_BALANCE, "quote credited");
        require(quote.allowance(PARTY_A, address(router)) == INITIAL_BALANCE, "quote allowance");
    }

    function testNoReturnDataTokenSettlesExactly() public {
        (FxSpotTrade customTrade, ReturnToken customQuote) = _customQuoteTrade();
        customQuote.setBehavior(ReturnToken.Behavior.NoData);
        vm.prank(PARTY_B);
        customTrade.confirmTrade("1", PARTY_A, PARTY_B, "terms", POSITION, PAYMENT, "settlement");
        require(customTrade.phase() == FxSpotTrade.Phase.Settled, "phase");
        require(router.consumedTrade(address(customTrade), keccak256("1")), "authorization");
        require(base.balanceOf(PARTY_A) == INITIAL_BALANCE + 100, "base receipt");
        require(customQuote.balanceOf(PARTY_A) == 0, "quote payment");
        require(customQuote.balanceOf(PARTY_B) == 200, "quote receipt");
        require(customQuote.allowance(PARTY_A, address(router)) == 0, "quote allowance");
    }

    function testFalseRevertingAndMalformedTokenResponsesRollBackAllEffects() public {
        (FxSpotTrade customTrade, ReturnToken customQuote) = _customQuoteTrade();
        ReturnToken.Behavior[3] memory failures = [
            ReturnToken.Behavior.False, ReturnToken.Behavior.Revert, ReturnToken.Behavior.ShortData
        ];
        for (uint256 i; i < failures.length; i++) {
            customQuote.setBehavior(failures[i]);
            vm.expectRevert(
                abi.encodeWithSelector(
                    ERC20PvPSettlementRouter.TransferFromFailed.selector,
                    address(customQuote)
                )
            );
            vm.prank(PARTY_B);
            customTrade.confirmTrade("1", PARTY_A, PARTY_B, "terms", POSITION, PAYMENT, "settlement");
            require(customTrade.phase() == FxSpotTrade.Phase.Incepted, "phase not restored");
            require(
                !router.consumedTrade(address(customTrade), keccak256("1")),
                "authorization not restored"
            );
            require(base.balanceOf(PARTY_A) == INITIAL_BALANCE, "first transfer survived");
            require(base.balanceOf(PARTY_B) == INITIAL_BALANCE, "base payer balance");
            require(base.allowance(PARTY_B, address(router)) == INITIAL_BALANCE, "base allowance");
            require(customQuote.balanceOf(PARTY_A) == 200, "token side effects survived");
            require(customQuote.balanceOf(PARTY_B) == 0, "quote recipient balance");
            require(customQuote.allowance(PARTY_A, address(router)) == 200, "quote allowance");
        }
    }

    function testCounterpartyCannotReenterAnyTradeActionDuringTransfer() public {
        ReturnToken callbackToken = new ReturnToken();
        ReentrantCounterparty counterparty = new ReentrantCounterparty();
        FxSpotTrade callbackTrade =
            _createTrade(callbackToken, _token(quote), PARTY_A, address(counterparty));
        callbackToken.mint(address(counterparty), 100);
        counterparty.approve(callbackToken, address(router), 100);
        callbackToken.setHook(counterparty);
        vm.prank(PARTY_A);
        callbackTrade.inceptTrade(
            PARTY_A, address(counterparty), "terms", POSITION, PAYMENT, "settlement"
        );
        counterparty.confirm(callbackTrade, PARTY_A);
        require(counterparty.attempted(), "callback not reached");
        require(counterparty.reentryError() == FxSpotTrade.ReentrantCall.selector, "reentry guard");
        require(
            counterparty.inceptionReentryError() == FxSpotTrade.ReentrantCall.selector,
            "inception guard"
        );
        require(
            counterparty.cancellationReentryError() == FxSpotTrade.ReentrantCall.selector,
            "cancel guard"
        );
        require(
            keccak256(bytes(callbackTrade.tradeId())) == keccak256("1"),
            "callback replaced latest trade"
        );
        require(callbackTrade.phase() == FxSpotTrade.Phase.Settled, "outer settlement failed");
        require(router.consumedTrade(address(callbackTrade), keccak256("1")), "authorization");
        require(callbackToken.balanceOf(PARTY_A) == 100, "base not transferred exactly once");
        require(quote.balanceOf(address(counterparty)) == 200, "quote not transferred exactly once");
        vm.prank(address(counterparty));
        callbackTrade.inceptTrade(
            address(counterparty), PARTY_A, "next terms", 100, -200, "settlement"
        );
        require(
            callbackTrade.getTrade("2").phase == FxSpotTrade.Phase.Incepted,
            "guard did not reopen after settlement"
        );
        require(
            callbackTrade.getTrade("1").phase == FxSpotTrade.Phase.Settled,
            "callback corrupted prior trade"
        );
    }

    function testReuseAfterSettlementNegotiatesNewAmountsAndRetainsHistory() public {
        _incept();
        _confirm();
        vm.prank(PARTY_A);
        string memory acceptedId =
            trade.inceptTrade(PARTY_A, PARTY_B, "new terms", 50, -125, "new data");
        require(keccak256(bytes(acceptedId)) == keccak256("2"), "wrong returned id");
        require(keccak256(bytes(trade.tradeId())) == keccak256("2"), "wrong latest id");
        require(router.registeredTrade(address(trade)), "registration consumed");
        require(!router.consumedTrade(address(trade), keccak256("2")), "new id consumed");
        vm.prank(PARTY_B);
        trade.confirmTrade("2", PARTY_A, PARTY_B, "new terms", 50, -125, "new data");

        require(base.balanceOf(PARTY_A) == INITIAL_BALANCE + 150, "combined base receipt");
        require(quote.balanceOf(PARTY_A) == INITIAL_BALANCE - 325, "combined quote payment");
        require(
            base.allowance(PARTY_B, address(router)) == INITIAL_BALANCE - 150,
            "base allowance reused"
        );
        require(
            quote.allowance(PARTY_A, address(router)) == INITIAL_BALANCE - 325,
            "quote allowance reused"
        );
        require(router.consumedTrade(address(trade), keccak256("1")), "first id lost");
        require(router.consumedTrade(address(trade), keccak256("2")), "second id not consumed");

        FxSpotTrade.Trade memory first = trade.getTrade("1");
        FxSpotTrade.Trade memory second = trade.getTrade("2");
        require(
            first.phase == FxSpotTrade.Phase.Settled && second.phase == FxSpotTrade.Phase.Settled,
            "history phases"
        );
        require(
            first.inceptor == PARTY_A && first.position == POSITION
                && first.paymentAmount == PAYMENT,
            "first amounts overwritten"
        );
        require(keccak256(bytes(first.tradeData)) == keccak256("terms"), "first terms overwritten");
        require(
            keccak256(bytes(first.initialSettlementData)) == keccak256("settlement"),
            "first data overwritten"
        );
        require(second.position == 50 && second.paymentAmount == -125, "second amounts");
        require(trade.position() == 50 && trade.paymentAmount() == -125, "latest getters");
    }

    function testCancellationGeneratesFreshIdAndRejectsStaleActionsForIdenticalTerms() public {
        string memory firstId = _incept();
        _cancel();
        vm.prank(PARTY_A);
        string memory secondId =
            trade.inceptTrade(PARTY_A, PARTY_B, "terms", POSITION, PAYMENT, "settlement");
        require(
            keccak256(bytes(firstId)) != keccak256(bytes(secondId)), "identical terms reused id"
        );
        vm.expectRevert(FxSpotTrade.InvalidPhase.selector);
        _confirm();
        vm.expectRevert(FxSpotTrade.InvalidPhase.selector);
        _cancel();
        require(trade.getTrade("1").phase == FxSpotTrade.Phase.Canceled, "canceled history changed");
        require(
            trade.getTrade("2").phase == FxSpotTrade.Phase.Incepted,
            "stale action changed new quote"
        );
        _assertOriginalBalancesAndAllowances();
        vm.prank(PARTY_B);
        trade.confirmTrade(secondId, PARTY_A, PARTY_B, "terms", POSITION, PAYMENT, "settlement");
        _assertSettled();
        require(router.consumedTrade(address(trade), keccak256("2")), "second id not consumed");
    }

    function testSettledIdCannotConfirmOrCancelIdenticalNewQuote() public {
        _incept();
        _confirm();
        vm.prank(PARTY_A);
        trade.inceptTrade(PARTY_A, PARTY_B, "terms", POSITION, PAYMENT, "settlement");
        vm.expectRevert(FxSpotTrade.InvalidPhase.selector);
        _confirm();
        vm.expectRevert(FxSpotTrade.InvalidPhase.selector);
        _cancel();
        require(trade.getTrade("2").phase == FxSpotTrade.Phase.Incepted, "new quote changed");
        require(base.balanceOf(PARTY_A) == INITIAL_BALANCE + 100, "stale transfer");
        vm.prank(PARTY_A);
        trade.cancelTrade("2", PARTY_A, PARTY_B, "terms", POSITION, PAYMENT, "settlement");
        require(trade.getTrade("1").phase == FxSpotTrade.Phase.Settled, "settled history changed");
    }

    function testNewInceptionCannotOverwritePendingTrade() public {
        _incept();
        vm.expectRevert(FxSpotTrade.InvalidPhase.selector);
        vm.prank(PARTY_B);
        trade.inceptTrade(PARTY_B, PARTY_A, "new terms", -50, 150, "new data");
        _assertOpenAndUnspent();
        require(keccak256(bytes(trade.tradeId())) == keccak256("1"), "pending id replaced");
        require(
            trade.position() == POSITION && trade.paymentAmount() == PAYMENT, "pending terms replaced"
        );
        _cancel();
        require(keccak256(bytes(_incept())) == keccak256("2"), "rejected inception consumed id");
    }

    function testEmptyAndUnknownIdsCannotReadConfirmOrCancelTrade() public {
        vm.expectRevert(FxSpotTrade.UnknownTrade.selector);
        trade.getTrade("1");
        vm.expectRevert(FxSpotTrade.UnknownTrade.selector);
        trade.getTrade("");
        _incept();
        vm.expectRevert(FxSpotTrade.InvalidPhase.selector);
        vm.prank(PARTY_B);
        trade.confirmTrade("", PARTY_A, PARTY_B, "terms", POSITION, PAYMENT, "settlement");
        vm.expectRevert(FxSpotTrade.InvalidPhase.selector);
        vm.prank(PARTY_A);
        trade.cancelTrade("", PARTY_A, PARTY_B, "terms", POSITION, PAYMENT, "settlement");
        vm.expectRevert(FxSpotTrade.InvalidPhase.selector);
        vm.prank(PARTY_B);
        trade.confirmTrade("unknown", PARTY_A, PARTY_B, "terms", POSITION, PAYMENT, "settlement");
        vm.expectRevert(FxSpotTrade.InvalidPhase.selector);
        vm.prank(PARTY_A);
        trade.cancelTrade("unknown", PARTY_A, PARTY_B, "terms", POSITION, PAYMENT, "settlement");
        _assertOpenAndUnspent();
    }

    function testGeneratedIdsRemainUniqueAcrossRepeatedIdenticalQuotesAndDecimalBoundary() public {
        string[12] memory ids;
        for (uint256 i; i < ids.length; i++) {
            ids[i] = _incept();
            require(bytes(ids[i]).length != 0, "empty generated id");
            for (uint256 j; j < i; j++) {
                require(keccak256(bytes(ids[j])) != keccak256(bytes(ids[i])), "generated id reused");
                require(
                    trade.getTrade(ids[j]).phase == FxSpotTrade.Phase.Canceled,
                    "history overwritten"
                );
            }
            vm.prank(PARTY_A);
            trade.cancelTrade(ids[i], PARTY_A, PARTY_B, "terms", POSITION, PAYMENT, "settlement");
            require(
                router.consumedTrade(address(trade), keccak256(bytes(ids[i]))), "id not consumed"
            );
        }
        require(keccak256(bytes(ids[8])) == keccak256("9"), "ninth id");
        require(keccak256(bytes(ids[9])) == keccak256("10"), "tenth id");
        require(keccak256(bytes(ids[11])) == keccak256("12"), "twelfth id");
        _assertOriginalBalancesAndAllowances();
    }

    function testOperatorApprovalPersistsAcrossTradesAndRevocationStillApplies() public {
        vm.prank(PARTY_A);
        trade.setTradeOperator(OUTSIDER, true);
        vm.prank(OUTSIDER);
        trade.inceptTrade(PARTY_A, PARTY_B, "terms", POSITION, PAYMENT, "settlement");
        _confirm();
        vm.prank(OUTSIDER);
        trade.inceptTrade(PARTY_A, PARTY_B, "terms", POSITION, PAYMENT, "settlement");
        vm.prank(PARTY_A);
        trade.setTradeOperator(OUTSIDER, false);
        _expectUnauthorized(OUTSIDER, PARTY_A);
        vm.prank(OUTSIDER);
        trade.cancelTrade("2", PARTY_A, PARTY_B, "terms", POSITION, PAYMENT, "settlement");
        vm.prank(PARTY_A);
        trade.cancelTrade("2", PARTY_A, PARTY_B, "terms", POSITION, PAYMENT, "settlement");
        _expectUnauthorized(OUTSIDER, PARTY_A);
        vm.prank(OUTSIDER);
        trade.inceptTrade(PARTY_A, PARTY_B, "terms", POSITION, PAYMENT, "settlement");
        require(trade.getTrade("1").phase == FxSpotTrade.Phase.Settled, "settled trade changed");
        require(trade.getTrade("2").phase == FxSpotTrade.Phase.Canceled, "canceled trade changed");
    }

    function testLaterSettlementFailureRollsBackOnlyThatTradeAndCanRetry() public {
        _incept();
        _confirm();
        vm.prank(PARTY_A);
        trade.inceptTrade(PARTY_A, PARTY_B, "second", POSITION, PAYMENT, "data");
        vm.prank(PARTY_A);
        quote.approve(address(router), 0);
        vm.expectRevert(
            abi.encodeWithSelector(
                ERC20PvPSettlementRouter.TransferFromFailed.selector, address(quote)
            )
        );
        vm.prank(PARTY_B);
        trade.confirmTrade("2", PARTY_A, PARTY_B, "second", POSITION, PAYMENT, "data");
        require(base.balanceOf(PARTY_A) == INITIAL_BALANCE + 100, "second base transfer survived");
        require(quote.balanceOf(PARTY_A) == INITIAL_BALANCE - 200, "prior quote payment changed");
        require(
            base.allowance(PARTY_B, address(router)) == INITIAL_BALANCE - 100,
            "second allowance consumed"
        );
        require(trade.getTrade("1").phase == FxSpotTrade.Phase.Settled, "first state changed");
        require(
            trade.getTrade("2").phase == FxSpotTrade.Phase.Incepted, "second state not restored"
        );
        require(router.consumedTrade(address(trade), keccak256("1")), "prior consumption changed");
        require(
            !router.consumedTrade(address(trade), keccak256("2")), "second consumption not restored"
        );
        vm.prank(PARTY_A);
        quote.approve(address(router), INITIAL_BALANCE);
        vm.prank(PARTY_B);
        trade.confirmTrade("2", PARTY_A, PARTY_B, "second", POSITION, PAYMENT, "data");
        require(base.balanceOf(PARTY_A) == INITIAL_BALANCE + 200, "retry base receipt");
        require(quote.balanceOf(PARTY_A) == INITIAL_BALANCE - 400, "retry quote payment");
    }

    function testRouterRejectsEmptyIdsAndDuplicateRegistrationAfterTrade() public {
        vm.expectRevert(ERC20PvPSettlementRouter.InvalidTradeId.selector);
        vm.prank(address(trade));
        router.cancelPvP("");
        vm.expectRevert(ERC20PvPSettlementRouter.InvalidTradeId.selector);
        vm.prank(address(trade));
        router.settlePvP(
            "", _token(base), _token(quote), PARTY_A, PARTY_B, POSITION, PAYMENT
        );
        _incept();
        _cancel();
        vm.expectRevert(ERC20PvPSettlementRouter.InvalidTrade.selector);
        vm.prank(address(factory));
        router.registerTrade(address(trade));
        require(router.registeredTrade(address(trade)), "registration lost");
        require(router.consumedTrade(address(trade), keccak256("1")), "tombstone reset");
    }

    function testFuzzReuseCanChangeInceptorAndDirection(bool bIncepts, bool receivesBase) public {
        _incept();
        _confirm();
        address initiator = bIncepts ? PARTY_B : PARTY_A;
        address confirmer = bIncepts ? PARTY_A : PARTY_B;
        int256 secondPosition = receivesBase ? int256(40) : int256(-40);
        int256 secondPayment = receivesBase ? int256(-75) : int256(75);
        uint256 baseBefore = base.balanceOf(initiator);
        uint256 quoteBefore = quote.balanceOf(initiator);
        vm.prank(initiator);
        trade.inceptTrade(initiator, confirmer, "second", secondPosition, secondPayment, "data");
        vm.prank(confirmer);
        trade.confirmTrade(
            "2", initiator, confirmer, "second", secondPosition, secondPayment, "data"
        );
        require(
            base.balanceOf(initiator) == (receivesBase ? baseBefore + 40 : baseBefore - 40),
            "second base direction"
        );
        require(
            quote.balanceOf(initiator) == (receivesBase ? quoteBefore - 75 : quoteBefore + 75),
            "second quote direction"
        );
        require(trade.inceptor() == initiator, "second inceptor");
        require(trade.getTrade("1").inceptor == PARTY_A, "first inceptor changed");
    }

    function testUnsupportedTerminationOperationsRevert() public {
        vm.expectRevert(FxSpotTrade.TerminationNotSupported.selector);
        trade.requestTradeTermination("1", PARTY_A, 0, "terms");
        vm.expectRevert(FxSpotTrade.TerminationNotSupported.selector);
        trade.confirmTradeTermination("1", PARTY_A, 0, "terms");
        vm.expectRevert(FxSpotTrade.TerminationNotSupported.selector);
        trade.cancelTradeTermination("1", PARTY_A, 0, "terms");
    }

    function _expectUnauthorized(address caller, address party) private {
        vm.expectRevert(
            abi.encodeWithSelector(
                TradeAuthorizable.UnauthorizedTradeCaller.selector, caller, party
            )
        );
    }

    function _customQuoteTrade() private returns (FxSpotTrade customTrade, ReturnToken customQuote) {
        customQuote = new ReturnToken();
        customTrade = _createTrade(_token(base), customQuote, PARTY_A, PARTY_B);
        customQuote.mint(PARTY_A, 200);
        vm.prank(PARTY_A);
        customQuote.approve(address(router), 200);
        vm.prank(PARTY_A);
        customTrade.inceptTrade(PARTY_A, PARTY_B, "terms", POSITION, PAYMENT, "settlement");
    }

    function _createTrade(
        IERC20RouterToken baseToken,
        IERC20RouterToken quoteToken,
        address a,
        address b
    ) private returns (FxSpotTrade) {
        vm.prank(a);
        return FxSpotTrade(factory.createTrade(baseToken, quoteToken, a, b));
    }

    function _fundAndApprove(ERC20TokenExample token, address party) private {
        token.mint(party, INITIAL_BALANCE);
        vm.prank(party);
        token.approve(address(router), INITIAL_BALANCE);
    }

    function _token(ERC20TokenExample token) private pure returns (IERC20RouterToken) {
        return IERC20RouterToken(address(token));
    }

    function _incept() private returns (string memory) {
        vm.prank(PARTY_A);
        return trade.inceptTrade(PARTY_A, PARTY_B, "terms", POSITION, PAYMENT, "settlement");
    }

    function _confirm() private {
        vm.prank(PARTY_B);
        trade.confirmTrade("1", PARTY_A, PARTY_B, "terms", POSITION, PAYMENT, "settlement");
    }

    function _cancel() private {
        vm.prank(PARTY_A);
        trade.cancelTrade("1", PARTY_A, PARTY_B, "terms", POSITION, PAYMENT, "settlement");
    }

    function _assertTerminalCallsRevert() private {
        vm.expectRevert(FxSpotTrade.InvalidPhase.selector);
        _confirm();
        vm.expectRevert(FxSpotTrade.InvalidPhase.selector);
        _cancel();
        vm.expectRevert(ERC20PvPSettlementRouter.TradeAlreadyConsumed.selector);
        vm.prank(address(trade));
        router.settlePvP(
            "1", _token(base), _token(quote), PARTY_A, PARTY_B, POSITION, PAYMENT
        );
        vm.expectRevert(ERC20PvPSettlementRouter.TradeAlreadyConsumed.selector);
        vm.prank(address(trade));
        router.cancelPvP("1");
    }

    function _assertOriginalBalancesAndAllowances() private view {
        require(base.balanceOf(PARTY_A) == INITIAL_BALANCE, "base A balance");
        require(base.balanceOf(PARTY_B) == INITIAL_BALANCE, "base B balance");
        require(quote.balanceOf(PARTY_A) == INITIAL_BALANCE, "quote A balance");
        require(quote.balanceOf(PARTY_B) == INITIAL_BALANCE, "quote B balance");
        require(base.allowance(PARTY_A, address(router)) == INITIAL_BALANCE, "base A allowance");
        require(base.allowance(PARTY_B, address(router)) == INITIAL_BALANCE, "base B allowance");
        require(quote.allowance(PARTY_A, address(router)) == INITIAL_BALANCE, "quote A allowance");
        require(quote.allowance(PARTY_B, address(router)) == INITIAL_BALANCE, "quote B allowance");
    }

    function _assertOpenAndUnspent() private view {
        require(trade.phase() == FxSpotTrade.Phase.Incepted, "phase");
        require(!router.consumedTrade(address(trade), keccak256("1")), "authorization");
        _assertOriginalBalancesAndAllowances();
    }

    function _assertSettled() private view {
        require(trade.phase() == FxSpotTrade.Phase.Settled, "phase");
        require(router.consumedTrade(address(trade), keccak256("1")), "authorization");
        require(base.balanceOf(PARTY_A) == INITIAL_BALANCE + 100, "base A balance");
        require(base.balanceOf(PARTY_B) == INITIAL_BALANCE - 100, "base B balance");
        require(quote.balanceOf(PARTY_A) == INITIAL_BALANCE - 200, "quote A balance");
        require(quote.balanceOf(PARTY_B) == INITIAL_BALANCE + 200, "quote B balance");
        require(base.allowance(PARTY_B, address(router)) == INITIAL_BALANCE - 100, "base allowance");
        require(
            quote.allowance(PARTY_A, address(router)) == INITIAL_BALANCE - 200, "quote allowance"
        );
    }
}
