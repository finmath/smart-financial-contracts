#!/usr/bin/env python3
"""Run the FX Spot Trade lifecycle on an owned, disposable local Anvil chain.

Requires Python 3.9+ and Foundry (forge, cast, anvil). Uses only the Python
standard library; cast performs ABI encoding/decoding, never RPC or signing.
"""

import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import shutil
import signal
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request
import uuid


ROOT = Path(__file__).resolve().parents[1]
CHAIN_ID = 31337
BASE_QTY = 10**18
QUOTE_QTY = 1_100_000
TRADE_TYPES = "address,address,string,int256,int256,string"
TRADE_RESULT = "(uint8,address,int256,int256,string,string)"
PHASES = ["Created", "Incepted", "Settled", "Canceled"]


def utc_now():
    return datetime.now(timezone.utc).isoformat()


def check(condition, message):
    # Do not use Python assert: these checks also run with python -O.
    if not condition:
        raise RuntimeError(message)


def command(*arguments, timeout=30):
    result = subprocess.run(arguments, cwd=ROOT, text=True, capture_output=True,
                            timeout=timeout, check=False)
    if result.returncode:
        raise RuntimeError(f"{arguments[0]} {arguments[1]} failed: "
                           f"{result.stderr.strip() or result.stdout.strip()}")
    return result.stdout.strip()


def calldata(signature, arguments=()):
    return command("cast", "calldata", "--", signature,
                   *(str(value).lower() if isinstance(value, bool) else str(value)
                     for value in arguments))


def decode(signature, data):
    return json.loads(command("cast", "abi-decode", "--json", signature, data))[0]


class Demo:
    def __init__(self, output):
        self.output = output
        self.process = None
        self.log = None
        self.rpc_url = None
        # The chain is local; ignore shell proxy configuration completely.
        self.http = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        self.report = {"status": "running", "startedAt": utc_now(),
                       "chainId": CHAIN_ID, "steps": [], "transactions": [],
                       "snapshots": [], "contracts": {}, "actors": {}}
        self.ids = []
        self.expected_terms = {}

    def save(self):
        temporary = self.output / "report.json.tmp"
        temporary.write_text(json.dumps(self.report, indent=2) + "\n", encoding="utf-8")
        temporary.replace(self.output / "report.json")

    def step(self, name, action):
        print(name, flush=True)
        record = {"name": name, "status": "running", "startedAt": utc_now()}
        self.report["steps"].append(record)
        self.save()
        try:
            result = action()
            record["status"] = "passed"
            return result
        except BaseException:
            record["status"] = "failed"
            raise
        finally:
            record["finishedAt"] = utc_now()
            self.save()

    def rpc(self, method, params):
        request = urllib.request.Request(self.rpc_url, headers={"Content-Type": "application/json"},
            data=json.dumps({"jsonrpc": "2.0", "id": 1, "method": method,
                             "params": params}).encode("utf-8"))
        with self.http.open(request, timeout=10) as response:
            result = json.load(response)
        if "error" in result:
            raise RuntimeError(f"{method}: {result['error']}")
        return result["result"]

    def build(self):
        with (self.output / "build.log").open("w", encoding="utf-8") as log:
            result = subprocess.run(["forge", "build"], cwd=ROOT, text=True,
                                    stdout=log, stderr=subprocess.STDOUT, timeout=180)
        check(result.returncode == 0, f"forge build failed; see {self.output / 'build.log'}")

    def start(self):
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            port = sock.getsockname()[1]
        self.rpc_url = f"http://127.0.0.1:{port}"
        self.log = (self.output / "anvil.log").open("w", encoding="utf-8")
        self.process = subprocess.Popen(
            ["anvil", "--host", "127.0.0.1", "--port", str(port), "--chain-id", str(CHAIN_ID),
             "--silent"], cwd=ROOT, stdout=self.log, stderr=subprocess.STDOUT)
        self.report["chain"] = {"rpcUrl": self.rpc_url, "pid": self.process.pid, "managed": True}
        deadline = time.monotonic() + 20
        while True:
            check(self.process.poll() is None, "Anvil stopped during startup; see anvil.log")
            try:
                accounts = self.rpc("eth_accounts", [])
                break
            except (urllib.error.URLError, TimeoutError):
                check(time.monotonic() < deadline, "Timed out waiting for Anvil")
                time.sleep(0.1)
        check(int(self.rpc("eth_chainId", []), 16) == CHAIN_ID, "Unexpected chain ID")
        check("anvil" in self.rpc("web3_clientVersion", []).lower(), "Expected an Anvil chain")
        check(len(accounts) >= 4, "Anvil did not provide four demo accounts")
        self.deployer, self.a, self.b, self.operator = accounts[:4]
        self.report["actors"] = dict(zip(["deployer", "partyA", "partyB", "operator"], accounts))

    def stop(self):
        if self.process is not None:
            if self.process.poll() is None:
                self.process.terminate()
                try:
                    self.process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    self.process.kill()
                    self.process.wait(timeout=5)
            self.report["chain"]["stopped"] = True
        if self.log is not None:
            self.log.close()

    def transact(self, name, sender, address=None, data="0x", expect_success=True):
        transaction = {"from": sender, "data": data, "gas": hex(12_000_000)}
        if address:
            transaction["to"] = address
        tx_hash = self.rpc("eth_sendTransaction", [transaction])
        record = {"name": name, "transactionHash": tx_hash, "expectedSuccess": expect_success}
        self.report["transactions"].append(record)
        self.save()
        deadline = time.monotonic() + 30
        while True:
            receipt = self.rpc("eth_getTransactionReceipt", [tx_hash])
            if receipt is not None:
                break
            check(time.monotonic() < deadline, f"Timed out waiting for {tx_hash}")
            time.sleep(0.1)
        path = f"receipts/{len(self.report['transactions']):02d}.json"
        (self.output / path).write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
        record.update({"receipt": path, "status": receipt["status"],
                       "blockNumber": str(int(receipt["blockNumber"], 16))})
        self.save()
        check((int(receipt["status"], 16) == 1) == expect_success,
              f"Unexpected transaction status for {name}; see {path}")
        return receipt

    def send(self, name, sender, address, signature, *arguments, expect_success=True):
        return self.transact(name, sender, address, calldata(signature, arguments), expect_success)

    def call(self, address, signature, *arguments, block="latest"):
        result = self.rpc("eth_call", [{"to": address, "data": calldata(signature, arguments)}, block])
        return decode(signature, result)

    def deploy(self, name, constructor=None, arguments=()):
        artifact = json.loads((ROOT / "out" / f"{name}.sol" / f"{name}.json").read_text())
        bytecode = artifact["bytecode"]["object"]
        if not bytecode.startswith("0x"):
            bytecode = "0x" + bytecode
        if constructor:
            bytecode += command("cast", "abi-encode", "--", constructor,
                                *(str(argument) for argument in arguments))[2:]
        receipt = self.transact(f"Deploy {name}", self.deployer, data=bytecode)
        address = receipt["contractAddress"]
        check(address is not None, f"No deployed address for {name}")
        return address

    def deploy_contracts(self):
        self.base = self.deploy("ERC20TokenExample", "constructor(string,string,uint8)",
                                ("Example Base Token", "BASE", 18))
        self.quote = self.deploy("ERC20TokenExample", "constructor(string,string,uint8)",
                                 ("Example Quote Token", "QUOTE", 6))
        self.factory = self.deploy("FxSpotTradeFactory")
        self.router = self.call(self.factory, "settlementRouter()(address)")
        receipt = self.send("Create reusable trade", self.a, self.factory,
                            "createTrade(address,address,address,address)", self.base, self.quote,
                            self.a, self.b)
        topic = command("cast", "keccak", "TradeCreated(address,address,address,address,address,address)")
        events = [event for event in receipt["logs"]
                  if event["address"].lower() == self.factory.lower()
                  and event["topics"][0] == topic]
        check(len(events) == 1, "Expected exactly one TradeCreated event")
        self.trade = "0x" + events[0]["topics"][1][-40:]
        self.report["contracts"] = {"baseToken": self.base, "quoteToken": self.quote,
            "factory": self.factory, "settlementRouter": self.router, "trade": self.trade}
        check(self.call(self.router, "registeredTrade(address)(bool)", self.trade), "Trade not registered")
        for getter, expected in [("baseToken", self.base), ("quoteToken", self.quote),
                                 ("partyA", self.a), ("partyB", self.b), ("settlementRouter", self.router)]:
            check(self.call(self.trade, f"{getter}()(address)").lower() == expected.lower(),
                  f"Unexpected {getter}")
        block = self.rpc("eth_blockNumber", [])
        for name, address in [("trade", self.trade), ("base-token", self.base), ("quote-token", self.quote)]:
            template = self.call(address, "stateXmlTemplate()(string)", block=block)
            (self.output / "templates" / f"{name}.xml").write_text(template, encoding="utf-8")
        self.report["templates"] = {"blockNumber": str(int(block, 16)),
            "description": "Raw ERC-8100 stateXmlTemplate() responses, not rendered contract state."}
        self.snapshot("Created", 0, "", [0, 0, 0, 0], [0, 0, 0, 0])

    def snapshot(self, label, phase, trade_id, balances, allowances):
        block = self.rpc("eth_getBlockByNumber", ["latest", False])
        tag = block["number"]
        actual_balances, actual_allowances = [], []
        for token in [self.base, self.quote]:
            for party in [self.a, self.b]:
                actual_balances.append(int(self.call(token, "balanceOf(address)(uint256)", party, block=tag)))
                actual_allowances.append(int(self.call(token, "allowance(address,address)(uint256)",
                                                        party, self.router, block=tag)))
        actual_phase = int(self.call(self.trade, "phase()(uint8)", block=tag))
        actual_id = self.call(self.trade, "tradeId()(string)", block=tag)
        history = {}
        for identifier in self.ids:
            terms = self.call(self.trade, f"getTrade(string)({TRADE_RESULT})", identifier, block=tag)
            key = command("cast", "keccak", identifier)
            consumed = self.call(self.router, "consumedTrade(address,bytes32)(bool)", self.trade, key, block=tag)
            history[identifier] = {"phase": PHASES[int(terms[0])], "inceptor": terms[1],
                "position": str(terms[2]), "paymentAmount": str(terms[3]),
                "tradeData": terms[4], "initialSettlementData": terms[5], "consumed": consumed}
            expected = self.expected_terms[identifier]
            check(terms[1].lower() == expected[0].lower()
                  and int(terms[2]) == expected[3] and int(terms[3]) == expected[4]
                  and terms[4] == expected[2] and terms[5] == expected[5],
                  f"Retained terms changed for trade {identifier}")
            expected_phase = phase if identifier == trade_id else (3 if identifier == "2" else 2)
            check(int(terms[0]) == expected_phase, f"Unexpected historical phase for trade {identifier}")
            check(consumed == (expected_phase in (2, 3)), f"Unexpected consumed state for trade {identifier}")
        snapshot = {"label": label, "blockNumber": str(int(tag, 16)), "blockHash": block["hash"],
            "phase": PHASES[actual_phase], "tradeId": actual_id,
            "balances": dict(zip(["partyABase", "partyBBase", "partyAQuote", "partyBQuote"],
                                  map(str, actual_balances))),
            "routerAllowances": dict(zip(["partyABase", "partyBBase", "partyAQuote", "partyBQuote"],
                                          map(str, actual_allowances))), "trades": history}
        self.report["snapshots"].append(snapshot)
        self.save()
        check(actual_phase == phase and actual_id == trade_id, f"Unexpected lifecycle state at {label}")
        check(actual_balances == balances, f"Unexpected balances at {label}: {actual_balances}")
        check(actual_allowances == allowances, f"Unexpected allowances at {label}: {actual_allowances}")

    def incept(self, sender, terms):
        self.send("Incept trade", sender, self.trade, f"inceptTrade({TRADE_TYPES})", *terms)
        identifier = self.call(self.trade, "tradeId()(string)")
        check(identifier == str(len(self.ids) + 1), "Unexpected contract-generated trade ID")
        self.ids.append(identifier)
        self.expected_terms[identifier] = terms
        return identifier

    def workflow(self):
        initial = [0, 5 * BASE_QTY, 10_000_000, 0]
        settled = [BASE_QTY, 4 * BASE_QTY, 8_900_000, QUOTE_QTY]
        final = [2 * BASE_QTY, 3 * BASE_QTY, 7_800_000, 2 * QUOTE_QTY]
        zero_allowances = [0, 0, 0, 0]
        terms = (self.a, self.b, "1 BASE for 1.10 QUOTE", BASE_QTY, -QUOTE_QTY, "atomic ERC-20 PvP")

        def fund():
            self.send("Fund Party B with 5 BASE", self.deployer, self.base,
                      "mint(address,uint256)", self.b, initial[1])
            self.send("Fund Party A with 10 QUOTE", self.deployer, self.quote,
                      "mint(address,uint256)", self.a, initial[2])
            self.send("Party B approves BASE router allowance", self.b, self.base,
                      "approve(address,uint256)", self.router, BASE_QTY)
            self.snapshot("Funded; BASE leg approved", 0, "", initial, [0, BASE_QTY, 0, 0])
        self.step("Fund the participants and approve the BASE leg", fund)

        def rollback():
            identifier = self.incept(self.a, terms)
            self.snapshot("Incepted", 1, identifier, initial, [0, BASE_QTY, 0, 0])
            self.send("Confirmation fails without QUOTE allowance", self.b, self.trade,
                      f"confirmTrade(string,{TRADE_TYPES})", identifier, *terms, expect_success=False)
            self.snapshot("Failed settlement rolled back both legs", 1, identifier, initial,
                          [0, BASE_QTY, 0, 0])
        self.step("Verify atomic rollback when the QUOTE leg is not approved", rollback)

        def settle():
            self.send("Party A approves QUOTE router allowance", self.a, self.quote,
                      "approve(address,uint256)", self.router, QUOTE_QTY)
            self.send("Confirm and settle trade 1", self.b, self.trade,
                      f"confirmTrade(string,{TRADE_TYPES})", "1", *terms)
            self.snapshot("Settled", 2, "1", settled, zero_allowances)
        self.step("Confirm trade 1 and verify both exact token transfers", settle)

        def cancel():
            reversed_terms = (self.b, self.a, "Withdrawn quote", -BASE_QTY, QUOTE_QTY, terms[-1])
            identifier = self.incept(self.b, reversed_terms)
            self.snapshot("Second quote incepted by Party B", 1, identifier, settled, zero_allowances)
            self.send("Party B cancels trade 2", self.b, self.trade,
                      f"cancelTrade(string,{TRADE_TYPES})", identifier, *reversed_terms)
            self.snapshot("Canceled without transfers", 3, identifier, settled, zero_allowances)
        self.step("Reuse the same trade instance and cancel a new quote", cancel)

        def operator_trade():
            for party in [self.a, self.b]:
                self.send("Approve trade operator", party, self.trade,
                          "setTradeOperator(address,bool)", self.operator, True)
            for party, token, amount in [(self.a, self.quote, QUOTE_QTY), (self.b, self.base, BASE_QTY)]:
                self.send("Renew token router allowance", party, token,
                          "approve(address,uint256)", self.router, amount)
            identifier = self.incept(self.operator, terms)
            self.snapshot("Operator incepted trade 3 for Party A", 1, identifier, settled,
                          [0, BASE_QTY, QUOTE_QTY, 0])
            self.send("Operator confirms trade 3 for Party B", self.operator, self.trade,
                      f"confirmTrade(string,{TRADE_TYPES})", identifier, *terms)
            for party in [self.a, self.b]:
                self.send("Revoke trade operator", party, self.trade,
                          "setTradeOperator(address,bool)", self.operator, False)
                check(not self.call(self.trade, "isTradeOperator(address,address)(bool)", party,
                                    self.operator), "Operator approval was not revoked")
            self.snapshot("Operator settlement completed; approvals revoked", 2, identifier, final,
                          zero_allowances)
        self.step("Settle trade 3 through an approved operator and retain earlier records", operator_trade)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path,
                        help="Fresh evidence directory; default: target/headless-demo/<unique run>")
    options = parser.parse_args()
    for executable in ["forge", "cast", "anvil"]:
        if shutil.which(executable) is None:
            parser.error(f"{executable} is required on PATH")
    output = options.output or ROOT / "target" / "headless-demo" / (
        datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ-") + uuid.uuid4().hex[:8])
    output = output.resolve()
    try:
        output.mkdir(parents=True, exist_ok=False)
    except OSError as failure:
        parser.error(f"Cannot create fresh output directory {output}: {failure}")
    for directory in ["receipts", "templates"]:
        (output / directory).mkdir()
    demo = Demo(output)
    print(f"Headless FX Spot Trade demo\nEvidence: {output}", flush=True)

    def interrupted(signum, frame):
        raise KeyboardInterrupt()

    signal.signal(signal.SIGTERM, interrupted)
    exit_code = 0
    try:
        demo.step("Build FX contracts", demo.build)
        demo.step("Start a disposable local Anvil chain", demo.start)
        demo.step("Deploy tokens, factory and reusable trade", demo.deploy_contracts)
        demo.workflow()
        demo.report["status"] = "passed"
    except (Exception, KeyboardInterrupt) as failure:
        demo.report["status"] = "interrupted" if isinstance(failure, KeyboardInterrupt) else "failed"
        demo.report["error"] = str(failure) or "Interrupted"
        print(f"FAIL: {demo.report['error']}", file=sys.stderr)
        exit_code = 130 if isinstance(failure, KeyboardInterrupt) else 1
    finally:
        try:
            demo.stop()
        except (Exception, KeyboardInterrupt) as failure:
            demo.report["status"] = "failed"
            demo.report["cleanupError"] = str(failure) or "Interrupted during cleanup"
            print(f"FAIL during cleanup: {demo.report['cleanupError']}", file=sys.stderr)
            exit_code = 1
        finally:
            demo.report["finishedAt"] = utc_now()
            demo.save()
    if exit_code == 0:
        print("PASS: settlement, rollback, cancellation, reuse and operator workflow")
        print("Final balances: Party A = 2 BASE / 7.80 QUOTE; Party B = 3 BASE / 2.20 QUOTE")
    print(f"Report: {output / 'report.json'}")
    return exit_code


if __name__ == "__main__":
    sys.exit(main())
