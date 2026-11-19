import com.fasterxml.jackson.databind.ObjectMapper;
import net.finmath.smartcontracts.representablestate.xml.EvmXmlRenderer;
import net.finmath.smartcontracts.representablestate.xml.EvmXmlValidator;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.CsvSource;
import org.web3j.abi.FunctionEncoder;
import org.web3j.abi.FunctionReturnDecoder;
import org.web3j.abi.TypeReference;
import org.web3j.abi.datatypes.Address;
import org.web3j.abi.datatypes.Function;
import org.web3j.abi.datatypes.Type;
import org.web3j.abi.datatypes.Utf8String;
import org.web3j.abi.datatypes.generated.Int256;
import org.web3j.abi.datatypes.generated.Uint256;
import org.web3j.abi.datatypes.generated.Uint8;
import org.web3j.crypto.Hash;
import org.web3j.protocol.Web3j;
import org.web3j.protocol.core.DefaultBlockParameterName;
import org.web3j.protocol.core.methods.request.Transaction;
import org.web3j.protocol.core.methods.response.TransactionReceipt;
import org.web3j.protocol.http.HttpService;
import org.web3j.tx.response.PollingTransactionReceiptProcessor;
import org.web3j.utils.Numeric;
import org.w3c.dom.Document;
import org.w3c.dom.Element;

import javax.xml.XMLConstants;
import javax.xml.parsers.DocumentBuilderFactory;
import javax.xml.transform.TransformerFactory;
import javax.xml.transform.dom.DOMResult;
import javax.xml.transform.dom.DOMSource;
import javax.xml.transform.stream.StreamResult;
import javax.xml.transform.stream.StreamSource;
import java.io.ByteArrayInputStream;
import java.io.StringWriter;
import java.math.BigInteger;
import java.net.ServerSocket;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Duration;
import java.util.Base64;
import java.util.HashSet;
import java.util.List;
import java.util.Set;
import java.util.concurrent.TimeUnit;

import static org.junit.jupiter.api.Assertions.*;

/** Real ERC-8100 rendering against fresh local deployments, without the web service. */
class FxSpotTradeXmlTest {
    private static final String ENVELOPE = "urn:smart-product-framework:financial-product:1.0";
    private static final String FX = "urn:example:fx-spot-trade";
    private static final String EVM = "urn:evm:state:1.0";
    private static final String ZERO_ADDRESS = "0x" + "0".repeat(40);
    private static final BigInteger BASE = BigInteger.ONE.shiftLeft(200).add(BigInteger.valueOf(17));
    private static final BigInteger QUOTE = BASE.add(BigInteger.valueOf(123));
    private static final String TERMS = "<Injected xmlns='urn:hostile'>FX & \"quote\"</Injected>";
    private static final String SETTLEMENT = "PvP <both legs> & 'exact amounts'";
    private static final Set<String> CALLS = Set.of("tradeId()(string)", "phase()(uint8)",
            "inceptor()(address)", "partyA()(address)", "partyB()(address)",
            "baseToken()(address)", "quoteToken()(address)", "settlementRouter()(address)",
            "position()(int256)", "paymentAmount()(int256)", "tradeData()(string)",
            "initialSettlementData()(string)");
    private static final Path ROOT = Path.of(System.getProperty("demo.root")).normalize();
    private static Process anvil;
    private static Web3j web3;
    private static EvmXmlRenderer renderer;
    private static EvmXmlValidator validator;
    private static List<String> accounts;

    @BeforeAll
    static void startChain() throws Exception {
        assertTrue(Files.isRegularFile(artifact("FxSpotTradeFactory")), "Run forge build first");
        int port;
        try (ServerSocket socket = new ServerSocket(0)) { port = socket.getLocalPort(); }
        Path log = Files.createDirectories(ROOT.resolve("test/xml/target")).resolve("anvil.log");
        anvil = new ProcessBuilder("anvil", "--host", "127.0.0.1", "--port", Integer.toString(port),
                "--chain-id", "31391", "--silent")
                .redirectErrorStream(true).redirectOutput(log.toFile()).start();
        web3 = Web3j.build(new HttpService("http://127.0.0.1:" + port));
        assertTimeoutPreemptively(Duration.ofSeconds(15), () -> {
            while (true) {
                assertTrue(anvil.isAlive(), () -> "Anvil stopped; see " + log);
                try { accounts = web3.ethAccounts().send().getAccounts(); break; }
                catch (java.io.IOException unavailable) { Thread.sleep(50); }
            }
        });
        renderer = EvmXmlRenderer.fromWeb3j(web3);
        validator = new EvmXmlValidator("xsd/evmstate-bindings.xsd",
                "xsd/smart-product-framework/smart-financial-product-envelope.xsd",
                "fx-spot-trade-state.xsd");
    }

    @AfterAll
    static void stopChain() throws Exception {
        if (web3 != null) web3.shutdown();
        if (anvil != null) {
            anvil.destroy();
            if (!anvil.waitFor(5, TimeUnit.SECONDS)) anvil.destroyForcibly().waitFor();
        }
    }

    @ParameterizedTest(name = "inceptor B={0}, receives base={1}")
    @CsvSource({"false,true", "false,false", "true,true", "true,false"})
    void rendersTermsAndLifecycleWithoutLosingPrecisionOrInterpretingTradeText(
            boolean inceptorIsB, boolean receivesBase) throws Exception {
        String a = accounts.get(0), b = accounts.get(1);
        String inceptor = inceptorIsB ? b : a, counterparty = inceptorIsB ? a : b;
        String base = deploy("ERC20TokenExample", List.of(new Utf8String("Base"),
                new Utf8String("BASE"), new Uint8(18)));
        String quote = deploy("ERC20TokenExample", List.of(new Utf8String("Quote"),
                new Utf8String("QUOTE"), new Uint8(6)));
        String factory = deploy("FxSpotTradeFactory", List.of());
        TransactionReceipt created = send(a, factory, "createTrade", List.of(
                new Address(base), new Address(quote), new Address(a), new Address(b)));
        String topic = Hash.sha3String("TradeCreated(address,address,address,address,address,address)");
        var event = created.getLogs().stream().filter(l -> l.getAddress().equalsIgnoreCase(factory)
                && l.getTopics().get(0).equals(topic)).findFirst().orElseThrow();
        String trade = "0x" + event.getTopics().get(1).substring(26);
        String router = call(trade, "settlementRouter", Address.class).toString();
        BigInteger initialBase = BASE.multiply(BigInteger.valueOf(4));
        BigInteger initialQuote = QUOTE.multiply(BigInteger.valueOf(4));
        for (String party : List.of(a, b)) {
            send(a, base, "mint", List.of(new Address(party), new Uint256(initialBase)));
            send(a, quote, "mint", List.of(new Address(party), new Uint256(initialQuote)));
            send(party, base, "approve", List.of(new Address(router), new Uint256(initialBase)));
            send(party, quote, "approve", List.of(new Address(router), new Uint256(initialQuote)));
        }

        String raw = call(trade, "stateXmlTemplate", Utf8String.class).toString();
        assertEquals(Files.readString(ROOT.resolve("resources/fx-spot-trade-template.xml")), raw);
        validateTemplate(raw);
        BigInteger createdBlock = block();
        String createdXml = checkRendered(trade, createdBlock, 0, "", ZERO_ADDRESS,
                BigInteger.ZERO, BigInteger.ZERO, "", "");
        BigInteger position = receivesBase ? BASE : BASE.negate();
        BigInteger payment = receivesBase ? QUOTE.negate() : QUOTE;
        List<Type> terms = List.of(new Address(inceptor), new Address(counterparty), new Utf8String(TERMS),
                new Int256(position), new Int256(payment), new Utf8String(SETTLEMENT));
        send(inceptor, trade, "inceptTrade", terms);
        checkRendered(trade, block(), 1, "1", inceptor, position, payment, TERMS, SETTLEMENT);
        assertEquals(createdXml, renderer.render(trade, createdBlock), "Historical snapshot changed");
        send(counterparty, trade, "confirmTrade", prepend("1", terms));
        checkRendered(trade, block(), 2, "1", inceptor, position, payment, TERMS, SETTLEMENT);
        assertEquals(initialBase.add(position), balance(base, inceptor));
        assertEquals(initialQuote.add(payment), balance(quote, inceptor));
        assertEquals(initialBase.subtract(position), balance(base, counterparty));
        assertEquals(initialQuote.subtract(payment), balance(quote, counterparty));

        List<Type> reversed = List.of(new Address(counterparty), new Address(inceptor), new Utf8String(TERMS),
                new Int256(position.negate()), new Int256(payment.negate()), new Utf8String(SETTLEMENT));
        send(counterparty, trade, "inceptTrade", reversed);
        checkRendered(trade, block(), 1, "2", counterparty, position.negate(), payment.negate(), TERMS, SETTLEMENT);
        send(counterparty, trade, "cancelTrade", prepend("2", reversed));
        checkRendered(trade, block(), 3, "2", counterparty, position.negate(), payment.negate(), TERMS, SETTLEMENT);
        assertEquals(initialBase.add(position), balance(base, inceptor));
        assertEquals(initialQuote.add(payment), balance(quote, inceptor));
    }

    private static void validateTemplate(String xml) throws Exception {
        validator.validate(xml);
        Document doc = parse(xml);
        Set<String> calls = new HashSet<>();
        var nodes = doc.getElementsByTagName("*");
        int count = 0;
        for (int i = 0; i < nodes.getLength(); i++) {
            Element e = (Element) nodes.item(i);
            if (e.hasAttributeNS(EVM, "call")) { calls.add(e.getAttributeNS(EVM, "call")); count++; }
        }
        assertEquals(CALLS, calls);
        assertEquals(12, count);
        Element docs = (Element) doc.getElementsByTagNameNS(ENVELOPE, "ProductDocumentationTemplate").item(0);
        String prefix = "data:application/xslt+xml;base64,";
        assertTrue(docs.getAttribute("href").startsWith(prefix));
        byte[] stylesheet = Base64.getDecoder().decode(docs.getAttribute("href").substring(prefix.length()));
        assertArrayEquals(Files.readAllBytes(ROOT.resolve("resources/fx-spot-trade-documentation.xslt")), stylesheet);
        assertEquals("keccak256-" + Numeric.toHexString(Hash.sha3(stylesheet)), docs.getAttribute("integrity"));
    }

    private static String checkRendered(String trade, BigInteger block, int phase, String id,
            String inceptor, BigInteger position, BigInteger payment, String terms, String settlement) throws Exception {
        String xml = renderer.render(trade, block);
        validator.validate(xml);
        Document doc = parse(xml);
        Element envelope = doc.getDocumentElement();
        assertEquals(ENVELOPE, envelope.getNamespaceURI());
        assertEquals("SmartFinancialProduct", envelope.getLocalName());
        assertEquals("FxSpotTrade", envelope.getAttribute("type"));
        assertEquals("1.0.0", envelope.getAttribute("schemaVersion"));
        assertEquals("1.0.0", envelope.getAttribute("typeVersion"));
        assertEquals(block.toString(), envelope.getAttributeNS(EVM, "block-number"));
        assertEquals(trade.toLowerCase(), envelope.getAttributeNS(EVM, "contract-address").toLowerCase());
        assertEquals("31391", envelope.getAttributeNS(EVM, "chain-id"));
        assertEquals(id, text(doc, "TradeId"));
        assertEquals(Integer.toString(phase), text(doc, "Phase"));
        assertEquals(inceptor.toLowerCase(), text(doc, "Inceptor").toLowerCase());
        assertEquals(position.toString(), text(doc, "Position"));
        assertEquals(payment.toString(), text(doc, "PaymentAmount"));
        assertEquals(terms, text(doc, "TradeData"));
        assertEquals(settlement, text(doc, "InitialSettlementData"));
        var parties = doc.getElementsByTagNameNS(FX, "Party");
        assertEquals(accounts.get(0).toLowerCase(), parties.item(0).getTextContent().toLowerCase());
        assertEquals(accounts.get(1).toLowerCase(), parties.item(1).getTextContent().toLowerCase());
        var tokens = doc.getElementsByTagNameNS(FX, "Token");
        assertEquals(call(trade, "baseToken", Address.class).toString().toLowerCase(),
                tokens.item(0).getTextContent().toLowerCase());
        assertEquals(call(trade, "quoteToken", Address.class).toString().toLowerCase(),
                tokens.item(1).getTextContent().toLowerCase());
        assertEquals(call(trade, "settlementRouter", Address.class).toString().toLowerCase(),
                doc.getElementsByTagNameNS(ENVELOPE, "SettlementRouter").item(0).getTextContent().toLowerCase());
        assertEquals(0, doc.getElementsByTagNameNS("urn:hostile", "Injected").getLength());
        assertFalse(xml.contains("evmstate:call="));
        Element docs = (Element) doc.getElementsByTagNameNS(ENVELOPE, "ProductDocumentationTemplate").item(0);
        byte[] stylesheet = Base64.getDecoder().decode(docs.getAttribute("href").split(",", 2)[1]);
        TransformerFactory tf = TransformerFactory.newInstance();
        tf.setFeature(XMLConstants.FEATURE_SECURE_PROCESSING, true);
        tf.setAttribute(XMLConstants.ACCESS_EXTERNAL_DTD, "");
        tf.setAttribute(XMLConstants.ACCESS_EXTERNAL_STYLESHEET, "");
        var transformer = tf.newTransformer(new StreamSource(new ByteArrayInputStream(stylesheet)));
        StringWriter html = new StringWriter();
        transformer.transform(new DOMSource(doc.getElementsByTagNameNS(FX, "FxSpotTrade").item(0)),
                new StreamResult(html));
        assertTrue(html.toString().contains(position.toString()), "Position lost precision in documentation");
        assertTrue(html.toString().contains(payment.toString()), "Payment lost precision in documentation");
        assertFalse(html.toString().contains("<Injected"), "Documentation interpreted trade text as markup");
        DOMResult resultTree = new DOMResult();
        transformer.transform(new DOMSource(doc.getElementsByTagNameNS(FX, "FxSpotTrade").item(0)), resultTree);
        Document page = (Document) resultTree.getNode();
        var rows = ((Element) page.getElementsByTagName("tbody").item(0)).getElementsByTagName("tr");
        String other = inceptor.equalsIgnoreCase(accounts.get(0)) ? accounts.get(1) : accounts.get(0);
        for (int i = 0; i < 2; i++) {
            var cells = ((Element) rows.item(i)).getElementsByTagName("td");
            BigInteger amount = i == 0 ? position : payment;
            assertEquals(i == 0 ? "base" : "quote", cells.item(0).getTextContent());
            assertEquals(amount.toString(), cells.item(2).getTextContent());
            assertEquals(phase == 0 ? "-" : (amount.signum() < 0 ? inceptor : other).toLowerCase(),
                    cells.item(3).getTextContent().toLowerCase(), "Payer differs from signed terms");
            assertEquals(phase == 0 ? "-" : (amount.signum() < 0 ? other : inceptor).toLowerCase(),
                    cells.item(4).getTextContent().toLowerCase(), "Receiver differs from signed terms");
        }
        Path output = Files.createDirectories(ROOT.resolve("test/xml/target/rendered"));
        Files.writeString(output.resolve(trade + "-" + id + "-" + phase + ".xml"), xml);
        return xml;
    }

    private static String text(Document doc, String name) {
        return doc.getElementsByTagNameNS(FX, name).item(0).getTextContent();
    }

    private static Document parse(String xml) throws Exception {
        DocumentBuilderFactory f = DocumentBuilderFactory.newInstance();
        f.setNamespaceAware(true);
        f.setFeature(XMLConstants.FEATURE_SECURE_PROCESSING, true);
        f.setFeature("http://apache.org/xml/features/disallow-doctype-decl", true);
        f.setAttribute(XMLConstants.ACCESS_EXTERNAL_DTD, "");
        f.setAttribute(XMLConstants.ACCESS_EXTERNAL_SCHEMA, "");
        return f.newDocumentBuilder().parse(new ByteArrayInputStream(xml.getBytes(StandardCharsets.UTF_8)));
    }

    private static Path artifact(String name) { return ROOT.resolve("out/" + name + ".sol/" + name + ".json"); }
    private static BigInteger block() throws Exception { return web3.ethBlockNumber().send().getBlockNumber(); }

    private static String deploy(String name, List<Type> arguments) throws Exception {
        String bytecode = new ObjectMapper().readTree(artifact(name).toFile()).path("bytecode").path("object").asText();
        String data = Numeric.prependHexPrefix(Numeric.cleanHexPrefix(bytecode))
                + FunctionEncoder.encodeConstructor(arguments);
        return transact(accounts.get(0), null, data).getContractAddress();
    }

    private static TransactionReceipt send(String from, String to, String function, List<Type> arguments) throws Exception {
        return transact(from, to, FunctionEncoder.encode(new Function(function, arguments, List.of())));
    }

    private static TransactionReceipt transact(String from, String to, String data) throws Exception {
        Transaction tx = Transaction.createFunctionCallTransaction(from, null, BigInteger.valueOf(2_000_000_000L),
                BigInteger.valueOf(15_000_000), to, data);
        var response = web3.ethSendTransaction(tx).send();
        assertFalse(response.hasError(), () -> response.getError().getMessage());
        var receipt = new PollingTransactionReceiptProcessor(web3, 20, 100).waitForTransactionReceipt(response.getTransactionHash());
        assertTrue(receipt.isStatusOK(), () -> "Transaction reverted: " + receipt.getTransactionHash());
        return receipt;
    }

    private static <T extends Type> Object call(String contract, String function, Class<T> result) throws Exception {
        return call(contract, function, List.of(), result);
    }

    private static <T extends Type> Object call(String contract, String function, List<Type> args, Class<T> result) throws Exception {
        Function fn = new Function(function, args, List.of(TypeReference.create(result)));
        var response = web3.ethCall(Transaction.createEthCallTransaction(accounts.get(0), contract,
                FunctionEncoder.encode(fn)), DefaultBlockParameterName.LATEST).send();
        assertFalse(response.hasError(), () -> response.getError().getMessage());
        return FunctionReturnDecoder.decode(response.getValue(), fn.getOutputParameters()).get(0).getValue();
    }

    private static BigInteger balance(String token, String party) throws Exception {
        return (BigInteger) call(token, "balanceOf", List.of(new Address(party)), Uint256.class);
    }

    private static List<Type> prepend(String id, List<Type> args) {
        var all = new java.util.ArrayList<Type>();
        all.add(new Utf8String(id)); all.addAll(args); return all;
    }
}
