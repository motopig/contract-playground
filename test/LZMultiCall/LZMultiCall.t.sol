// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {LZMultiCall} from "../../src/LZMultiCall/LZMultiCall.sol";
import {TransferDelegate} from "../../src/LZMultiCall/TransferDelegate.sol";
import {ILZMultiCall} from "../../src/LZMultiCall/interfaces/ILZMultiCall.sol";
import {ITransferDelegate} from "../../src/LZMultiCall/interfaces/ITransferDelegate.sol";

/// @dev 用于测试的 mock ERC20 代币
contract MockERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev 用于测试的接收合约，会记录收到的调用
contract MockTarget {
    uint256 public value;
    address public lastCaller;

    function setValue(uint256 _value) external payable {
        value = _value;
        lastCaller = msg.sender;
    }

    function revertingFunction() external pure {
        revert("MockTarget: revert");
    }

    receive() external payable {}
}

contract LZMultiCallTest is Test {
    LZMultiCall public multiCall;
    TransferDelegate public transferDelegate;
    MockERC20 public tokenA;
    MockERC20 public tokenB;
    MockTarget public target;

    uint256 internal signerKey;
    address internal signer;
    uint256 internal relayerKey;
    address internal relayer;
    address internal recipient = makeAddr("recipient");

    function setUp() public {
        (signer, signerKey) = makeAddrAndKey("signer");
        (relayer, relayerKey) = makeAddrAndKey("relayer");

        multiCall = new LZMultiCall();
        transferDelegate = TransferDelegate(address(multiCall.TRANSFER_DELEGATE()));

        tokenA = new MockERC20("Token A", "TKA");
        tokenB = new MockERC20("Token B", "TKB");
        target = new MockTarget();

        // 给 signer 一些代币和 ETH
        tokenA.mint(signer, 1000 ether);
        tokenB.mint(signer, 500 ether);
        vm.deal(signer, 10 ether);
        vm.deal(relayer, 10 ether);
    }

    // ═══════════════════════════════════════════════════════════════
    //  辅助函数
    // ═══════════════════════════════════════════════════════════════

    function _buildTransferCall(address token, address from, address to, uint256 amount)
        internal
        view
        returns (ILZMultiCall.Call memory)
    {
        return ILZMultiCall.Call({
            target: address(transferDelegate),
            value: 0,
            data: abi.encodeCall(TransferDelegate.delegateTransferFrom, (token, from, to, amount))
        });
    }

    function _buildSetValueCall(uint256 val) internal view returns (ILZMultiCall.Call memory) {
        return ILZMultiCall.Call({
            target: address(target),
            value: 0,
            data: abi.encodeCall(MockTarget.setValue, (val))
        });
    }

    function _buildETHTransferCall(address to, uint256 amount) internal pure returns (ILZMultiCall.Call memory) {
        return ILZMultiCall.Call({target: to, value: amount, data: ""});
    }

    function _signExecute(
        ILZMultiCall.Call[] memory calls,
        bytes32 quoteId,
        uint256 expiration,
        uint256 privateKey
    ) internal view returns (bytes memory) {
        bytes32 digest = multiCall.getDigestToSign(calls, quoteId, expiration, vm.addr(privateKey));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    // ═══════════════════════════════════════════════════════════════
    //  TransferDelegate 测试
    // ═══════════════════════════════════════════════════════════════

    function test_TransferDelegate_onlyLZMultiCall() public {
        vm.expectRevert(ITransferDelegate.OnlyLZMultiCall.selector);
        transferDelegate.delegateTransferFrom(address(tokenA), signer, recipient, 100);
    }

    function test_TransferDelegate_immutables() public view {
        assertEq(transferDelegate.LZ_MULTI_CALL(), address(multiCall));
    }

    // ═══════════════════════════════════════════════════════════════
    //  execute(calls, quoteId) — msg.sender 模式
    // ═══════════════════════════════════════════════════════════════

    function test_execute_directCall_singleArbitrary() public {
        ILZMultiCall.Call[] memory calls = new ILZMultiCall.Call[](1);
        calls[0] = _buildSetValueCall(42);

        vm.prank(signer);
        multiCall.execute(calls, bytes32("q1"));

        assertEq(target.value(), 42);
        assertEq(target.lastCaller(), address(multiCall));
        assertEq(multiCall.nonces(signer), 1);
    }

    function test_execute_directCall_multipleArbitrary() public {
        ILZMultiCall.Call[] memory calls = new ILZMultiCall.Call[](2);
        calls[0] = _buildSetValueCall(10);
        calls[1] = _buildSetValueCall(99);

        vm.prank(signer);
        multiCall.execute(calls, bytes32("q2"));

        // 最后一个调用的值生效
        assertEq(target.value(), 99);
        assertEq(multiCall.nonces(signer), 1);
    }

    function test_execute_directCall_withERC20Transfer() public {
        // signer 先授权 transferDelegate
        vm.prank(signer);
        tokenA.approve(address(transferDelegate), 100 ether);

        ILZMultiCall.Call[] memory calls = new ILZMultiCall.Call[](1);
        calls[0] = _buildTransferCall(address(tokenA), signer, recipient, 50 ether);

        vm.prank(signer);
        multiCall.execute(calls, bytes32("q3"));

        assertEq(tokenA.balanceOf(recipient), 50 ether);
        assertEq(tokenA.balanceOf(signer), 950 ether);
    }

    function test_execute_directCall_withETH() public {
        ILZMultiCall.Call[] memory calls = new ILZMultiCall.Call[](1);
        calls[0] = _buildETHTransferCall(recipient, 1 ether);

        vm.prank(signer);
        multiCall.execute{value: 1 ether}(calls, bytes32("q4"));

        assertEq(recipient.balance, 1 ether);
    }

    function test_execute_directCall_emitsExecuted() public {
        ILZMultiCall.Call[] memory calls = new ILZMultiCall.Call[](1);
        calls[0] = _buildSetValueCall(1);

        vm.expectEmit(true, true, false, true);
        emit ILZMultiCall.Executed(signer, bytes32("q5"), 0);

        vm.prank(signer);
        multiCall.execute(calls, bytes32("q5"));
    }

    function test_execute_directCall_emitsNativeTransfer() public {
        ILZMultiCall.Call[] memory calls = new ILZMultiCall.Call[](1);
        calls[0] = _buildETHTransferCall(recipient, 1 ether);

        vm.expectEmit(true, false, false, true);
        emit ILZMultiCall.NativeTransfer(recipient, 1 ether);

        vm.prank(signer);
        multiCall.execute{value: 1 ether}(calls, bytes32("q_eth"));
    }

    function test_execute_directCall_emptyCalls_incrementsNonce() public {
        ILZMultiCall.Call[] memory calls = new ILZMultiCall.Call[](0);

        vm.prank(signer);
        multiCall.execute(calls, bytes32("q_empty"));

        assertEq(multiCall.nonces(signer), 1);
    }

    function test_execute_directCall_nonceIncrements() public {
        ILZMultiCall.Call[] memory calls = new ILZMultiCall.Call[](0);

        vm.startPrank(signer);
        multiCall.execute(calls, bytes32("n1"));
        multiCall.execute(calls, bytes32("n2"));
        multiCall.execute(calls, bytes32("n3"));
        vm.stopPrank();

        assertEq(multiCall.nonces(signer), 3);
    }

    // ═══════════════════════════════════════════════════════════════
    //  execute(calls, quoteId, expiration, signer, signature) — 签名模式
    // ═══════════════════════════════════════════════════════════════

    function test_execute_withSignature_basic() public {
        ILZMultiCall.Call[] memory calls = new ILZMultiCall.Call[](1);
        calls[0] = _buildSetValueCall(123);

        uint256 expiration = block.timestamp + 1 hours;
        bytes32 quoteId = bytes32("sig1");

        bytes memory sig = _signExecute(calls, quoteId, expiration, signerKey);

        // relayer 提交交易
        vm.prank(relayer);
        multiCall.execute(calls, quoteId, expiration, signer, sig);

        assertEq(target.value(), 123);
        assertEq(multiCall.nonces(signer), 1);
    }

    function test_execute_withSignature_emitsEvent() public {
        ILZMultiCall.Call[] memory calls = new ILZMultiCall.Call[](1);
        calls[0] = _buildSetValueCall(1);

        uint256 expiration = block.timestamp + 1 hours;
        bytes32 quoteId = bytes32("sig_evt");
        bytes memory sig = _signExecute(calls, quoteId, expiration, signerKey);

        vm.expectEmit(true, true, false, true);
        emit ILZMultiCall.ExecutedWithSignature(signer, quoteId, 0);

        vm.prank(relayer);
        multiCall.execute(calls, quoteId, expiration, signer, sig);
    }

    function test_execute_withSignature_erc20Transfer() public {
        vm.prank(signer);
        tokenA.approve(address(transferDelegate), 200 ether);

        ILZMultiCall.Call[] memory calls = new ILZMultiCall.Call[](1);
        calls[0] = _buildTransferCall(address(tokenA), signer, recipient, 100 ether);

        uint256 expiration = block.timestamp + 1 hours;
        bytes32 quoteId = bytes32("sig_erc20");
        bytes memory sig = _signExecute(calls, quoteId, expiration, signerKey);

        vm.prank(relayer);
        multiCall.execute(calls, quoteId, expiration, signer, sig);

        assertEq(tokenA.balanceOf(recipient), 100 ether);
    }

    function test_execute_withSignature_multipleCallsMixed() public {
        vm.prank(signer);
        tokenA.approve(address(transferDelegate), 50 ether);

        ILZMultiCall.Call[] memory calls = new ILZMultiCall.Call[](2);
        calls[0] = _buildTransferCall(address(tokenA), signer, recipient, 50 ether);
        calls[1] = _buildSetValueCall(777);

        uint256 expiration = block.timestamp + 1 hours;
        bytes32 quoteId = bytes32("sig_mixed");
        bytes memory sig = _signExecute(calls, quoteId, expiration, signerKey);

        vm.prank(relayer);
        multiCall.execute(calls, quoteId, expiration, signer, sig);

        assertEq(tokenA.balanceOf(recipient), 50 ether);
        assertEq(target.value(), 777);
    }

    // ═══════════════════════════════════════════════════════════════
    //  错误路径测试
    // ═══════════════════════════════════════════════════════════════

    function test_revert_expired() public {
        ILZMultiCall.Call[] memory calls = new ILZMultiCall.Call[](1);
        calls[0] = _buildSetValueCall(1);

        uint256 expiration = block.timestamp - 1; // 已过期
        bytes32 quoteId = bytes32("exp");
        bytes memory sig = _signExecute(calls, quoteId, expiration, signerKey);

        vm.expectRevert(abi.encodeWithSelector(ILZMultiCall.Expired.selector, block.timestamp, expiration));
        vm.prank(relayer);
        multiCall.execute(calls, quoteId, expiration, signer, sig);
    }

    function test_revert_invalidSignature() public {
        ILZMultiCall.Call[] memory calls = new ILZMultiCall.Call[](1);
        calls[0] = _buildSetValueCall(1);

        uint256 expiration = block.timestamp + 1 hours;
        bytes32 quoteId = bytes32("bad_sig");

        // 用 relayer 的私钥签名但声称 signer 签的
        bytes memory badSig = _signExecute(calls, quoteId, expiration, relayerKey);

        vm.expectRevert(ILZMultiCall.InvalidSignature.selector);
        vm.prank(relayer);
        multiCall.execute(calls, quoteId, expiration, signer, badSig);
    }

    function test_revert_replaySignature() public {
        ILZMultiCall.Call[] memory calls = new ILZMultiCall.Call[](1);
        calls[0] = _buildSetValueCall(1);

        uint256 expiration = block.timestamp + 1 hours;
        bytes32 quoteId = bytes32("replay");
        bytes memory sig = _signExecute(calls, quoteId, expiration, signerKey);

        // 第一次成功
        vm.prank(relayer);
        multiCall.execute(calls, quoteId, expiration, signer, sig);

        // 第二次应失败（nonce 已递增，签名内嵌 nonce=0 不再有效）
        vm.expectRevert(ILZMultiCall.InvalidSignature.selector);
        vm.prank(relayer);
        multiCall.execute(calls, quoteId, expiration, signer, sig);
    }

    function test_revert_transferFromMismatch() public {
        vm.prank(signer);
        tokenA.approve(address(transferDelegate), 100 ether);

        // 构造一个 from != signer 的 transfer 调用
        ILZMultiCall.Call[] memory calls = new ILZMultiCall.Call[](1);
        calls[0] = ILZMultiCall.Call({
            target: address(transferDelegate),
            value: 0,
            data: abi.encodeCall(TransferDelegate.delegateTransferFrom, (address(tokenA), relayer, recipient, 50 ether))
        });

        vm.expectRevert(abi.encodeWithSelector(ILZMultiCall.InvalidFromAddress.selector, relayer, signer));
        vm.prank(signer);
        multiCall.execute(calls, bytes32("mismatch"));
    }

    function test_revert_invalidCalldataLength() public {
        // 让 calldata 长度不是 132 字节
        ILZMultiCall.Call[] memory calls = new ILZMultiCall.Call[](1);
        calls[0] = ILZMultiCall.Call({
            target: address(transferDelegate),
            value: 0,
            data: abi.encodeWithSelector(TransferDelegate.delegateTransferFrom.selector, address(tokenA), signer) // 太短
        });

        vm.expectRevert(
            abi.encodeWithSelector(ILZMultiCall.InvalidCalldataLength.selector, calls[0].data.length, 132)
        );
        vm.prank(signer);
        multiCall.execute(calls, bytes32("badlen"));
    }

    function test_revert_invalidSelector() public {
        // 构造正确长度但错误 selector 的 calldata
        bytes memory badData = abi.encodeWithSelector(bytes4(0xdeadbeef), address(tokenA), signer, recipient, 100);
        assertEq(badData.length, 132); // 确保长度正确

        ILZMultiCall.Call[] memory calls = new ILZMultiCall.Call[](1);
        calls[0] = ILZMultiCall.Call({target: address(transferDelegate), value: 0, data: badData});

        vm.expectRevert(abi.encodeWithSelector(ILZMultiCall.InvalidSelector.selector, bytes4(0xdeadbeef)));
        vm.prank(signer);
        multiCall.execute(calls, bytes32("badselector"));
    }

    function test_revert_callReverts_bubblesUp() public {
        ILZMultiCall.Call[] memory calls = new ILZMultiCall.Call[](1);
        calls[0] = ILZMultiCall.Call({
            target: address(target),
            value: 0,
            data: abi.encodeCall(MockTarget.revertingFunction, ())
        });

        vm.expectRevert("MockTarget: revert");
        vm.prank(signer);
        multiCall.execute(calls, bytes32("revert"));
    }

    // ═══════════════════════════════════════════════════════════════
    //  sweep 测试
    // ═══════════════════════════════════════════════════════════════

    function test_sweep_onlySelf() public {
        address[] memory tokens = new address[](0);

        vm.expectRevert(ILZMultiCall.OnlySelf.selector);
        multiCall.sweep(tokens, recipient);
    }

    function test_sweep_viaSelfCall() public {
        // 先往 multiCall 中存入一些 token 和 ETH
        tokenA.mint(address(multiCall), 100 ether);
        vm.deal(address(multiCall), 2 ether);

        // 构造一个 self-call sweep
        address[] memory tokens = new address[](2);
        tokens[0] = address(0); // ETH
        tokens[1] = address(tokenA);

        ILZMultiCall.Call[] memory calls = new ILZMultiCall.Call[](1);
        calls[0] = ILZMultiCall.Call({
            target: address(multiCall),
            value: 0,
            data: abi.encodeCall(LZMultiCall.sweep, (tokens, recipient))
        });

        vm.prank(signer);
        multiCall.execute(calls, bytes32("sweep"));

        assertEq(tokenA.balanceOf(recipient), 100 ether);
        assertEq(recipient.balance, 2 ether);
        assertEq(tokenA.balanceOf(address(multiCall)), 0);
        assertEq(address(multiCall).balance, 0);
    }

    // ═══════════════════════════════════════════════════════════════
    //  getDigestToSign 测试
    // ═══════════════════════════════════════════════════════════════

    function test_getDigestToSign_deterministic() public view {
        ILZMultiCall.Call[] memory calls = new ILZMultiCall.Call[](1);
        calls[0] = _buildSetValueCall(42);

        bytes32 digest1 = multiCall.getDigestToSign(calls, bytes32("d1"), 1000, signer);
        bytes32 digest2 = multiCall.getDigestToSign(calls, bytes32("d1"), 1000, signer);
        assertEq(digest1, digest2);
    }

    function test_getDigestToSign_differentQuoteId() public view {
        ILZMultiCall.Call[] memory calls = new ILZMultiCall.Call[](1);
        calls[0] = _buildSetValueCall(42);

        bytes32 digest1 = multiCall.getDigestToSign(calls, bytes32("a"), 1000, signer);
        bytes32 digest2 = multiCall.getDigestToSign(calls, bytes32("b"), 1000, signer);
        assertTrue(digest1 != digest2);
    }

    function test_getDigestToSign_differentExpiration() public view {
        ILZMultiCall.Call[] memory calls = new ILZMultiCall.Call[](1);
        calls[0] = _buildSetValueCall(42);

        bytes32 digest1 = multiCall.getDigestToSign(calls, bytes32("d"), 1000, signer);
        bytes32 digest2 = multiCall.getDigestToSign(calls, bytes32("d"), 2000, signer);
        assertTrue(digest1 != digest2);
    }

    function test_getDigestToSign_changesAfterNonceIncrement() public {
        ILZMultiCall.Call[] memory calls = new ILZMultiCall.Call[](1);
        calls[0] = _buildSetValueCall(42);

        bytes32 digestBefore = multiCall.getDigestToSign(calls, bytes32("n"), 1000, signer);

        // 递增 nonce
        vm.prank(signer);
        multiCall.execute(new ILZMultiCall.Call[](0), bytes32("inc"));

        bytes32 digestAfter = multiCall.getDigestToSign(calls, bytes32("n"), 1000, signer);
        assertTrue(digestBefore != digestAfter);
    }

    // ═══════════════════════════════════════════════════════════════
    //  重入保护测试
    // ═══════════════════════════════════════════════════════════════

    function test_revert_reentrancy() public {
        // 构造一个调用 multiCall.execute 的嵌套调用来测试重入
        ILZMultiCall.Call[] memory innerCalls = new ILZMultiCall.Call[](0);
        bytes memory innerData = abi.encodeWithSignature("execute((address,uint256,bytes)[],bytes32)", innerCalls, bytes32("inner"));

        ILZMultiCall.Call[] memory outerCalls = new ILZMultiCall.Call[](1);
        outerCalls[0] = ILZMultiCall.Call({target: address(multiCall), value: 0, data: innerData});

        vm.expectRevert(); // ReentrancyGuardReentrantCall
        vm.prank(signer);
        multiCall.execute(outerCalls, bytes32("outer"));
    }

    // ═══════════════════════════════════════════════════════════════
    //  receive ETH 测试
    // ═══════════════════════════════════════════════════════════════

    function test_receiveETH() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(multiCall).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(address(multiCall).balance, 1 ether);
    }

    // ═══════════════════════════════════════════════════════════════
    //  多代币批量转移测试
    // ═══════════════════════════════════════════════════════════════

    function test_execute_batchTransfers() public {
        vm.startPrank(signer);
        tokenA.approve(address(transferDelegate), 100 ether);
        tokenB.approve(address(transferDelegate), 200 ether);
        vm.stopPrank();

        ILZMultiCall.Call[] memory calls = new ILZMultiCall.Call[](2);
        calls[0] = _buildTransferCall(address(tokenA), signer, recipient, 50 ether);
        calls[1] = _buildTransferCall(address(tokenB), signer, recipient, 150 ether);

        uint256 expiration = block.timestamp + 1 hours;
        bytes32 quoteId = bytes32("batch");
        bytes memory sig = _signExecute(calls, quoteId, expiration, signerKey);

        vm.prank(relayer);
        multiCall.execute(calls, quoteId, expiration, signer, sig);

        assertEq(tokenA.balanceOf(recipient), 50 ether);
        assertEq(tokenB.balanceOf(recipient), 150 ether);
    }

    // ═══════════════════════════════════════════════════════════════
    //  Nonce 跳过（签名失效）
    // ═══════════════════════════════════════════════════════════════

    function test_nonceSkip_invalidatesPendingSignature() public {
        ILZMultiCall.Call[] memory calls = new ILZMultiCall.Call[](1);
        calls[0] = _buildSetValueCall(999);

        uint256 expiration = block.timestamp + 1 hours;
        bytes32 quoteId = bytes32("pending");
        bytes memory sig = _signExecute(calls, quoteId, expiration, signerKey);

        // signer 主动跳过 nonce（发一个空 execute）
        vm.prank(signer);
        multiCall.execute(new ILZMultiCall.Call[](0), bytes32("skip"));

        // 之前的签名现在失效了
        vm.expectRevert(ILZMultiCall.InvalidSignature.selector);
        vm.prank(relayer);
        multiCall.execute(calls, quoteId, expiration, signer, sig);
    }
}
