// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.25;

import "../../src/7702/GasDaddy.sol";
import "../../src/7702/SimpleSBT.sol";

import "forge-std/Test.sol";
import "forge-std/console.sol";

contract EIP7702Test is Test {
    SimpleSBT simpleSBT;
    GasDaddy gasDaddy;
    Vm.Wallet alice;
    Vm.Wallet bob;

    function setUp() public {
        vm.selectFork(vm.createFork("http://192.168.1.104:10005"));
        // Deploy SimpleSBT
        simpleSBT = new SimpleSBT("GasDaddy SBT", "GDSBT");
        console.log("SimpleSBT deployed to:", address(simpleSBT));
        // Deploy GasDaddy
        gasDaddy = new GasDaddy();
        console.log("GasDaddy deployed to:", address(gasDaddy));
        // create accounts
        alice = vm.createWallet("alice");
        bob = vm.createWallet("bob");
    }

    function testMintSponsor() public {
        console.log("Alice address:", alice.addr);
        console.log("Bob address:", bob.addr);
        // Bob gets some ether
        // vm.deal(bob.addr, 10 ether);
        // get bob nonce
        uint256 bob_nonce = vm.getNonce(bob.addr);
        console.log("Bob nonce:", bob_nonce);
        // Alice signs a delegation allowing `gasDaddy` to execute transactions on her behalf.
        Vm.SignedDelegation memory signedDelegation = vm.signDelegation(address(gasDaddy), alice.privateKey);

        // Bob attaches the signed delegation from Alice and broadcasts it.
        vm.startBroadcast(bob.privateKey);
        vm.attachDelegation(signedDelegation);

        // Verify that Alice's account now temporarily behaves as a smart contract.
        address aliceAddr = alice.addr;
        bytes memory code = aliceAddr.code;
        require(code.length > 0, "no code written to Alice");
        console.log("Code on Alice's account:", vm.toString(code));

        // call GasDaddy`s initialize function
        GasDaddy(aliceAddr).initialize();
        console.log("GasDaddy is initialized:", GasDaddy(aliceAddr).isInitialized());

        GasDaddy(aliceAddr).executeCall(address(simpleSBT), abi.encodeWithSignature("mint()"));
        // Verify that Alice received the SBT
        uint256 tokenId = simpleSBT.getTokenId(aliceAddr);
        console.log("Alice received tokenId:", tokenId);
        require(tokenId != 0, "Alice did not receive the SBT");
        // simpleSBT totalSupply
        console.log("SimpleSBT totalSupply:", simpleSBT.totalSupply());
        // simpleSBT balanceOf
        console.log("SimpleSBT balanceOf:", simpleSBT.balanceOf(aliceAddr));
        // bob eth balance
        console.log("Bob eth balance:", bob.addr.balance);
        // alice eth balance
        console.log("Alice eth balance:", alice.addr.balance);
        vm.stopBroadcast();
    }

    function testMintNoSponsor() public {
        console.log("Alice address:", alice.addr);
        console.log("Bob address:", bob.addr);
        // get bob nonce
        uint256 bob_nonce = vm.getNonce(bob.addr);
        console.log("Bob nonce:", bob_nonce);
        // get alice nonce
        uint256 alice_nonce = vm.getNonce(alice.addr);
        console.log("Alice nonce:", alice_nonce);
        // Alice signs a delegation allowing `gasDaddy` to execute transactions on her behalf.
        Vm.SignedDelegation memory signedDelegation =
            vm.signDelegation(address(gasDaddy), alice.privateKey, uint64(alice_nonce + 1));
        // Bob attaches the signed delegation from Alice and broadcasts it.
        vm.startBroadcast(alice.privateKey);
        alice_nonce = vm.getNonce(alice.addr);

        vm.attachDelegation(signedDelegation);

        // Verify that Alice's account now temporarily behaves as a smart contract.
        address aliceAddr = alice.addr;
        bytes memory code = aliceAddr.code;
        require(code.length > 0, "no code written to Alice");
        console.log("Code on Alice's account:", vm.toString(code));
        // assertEq(alice_code, bytes.concat(hex"ef0100", bytes20(address(impl_7702))));
        // call GasDaddy`s initialize function
        GasDaddy(aliceAddr).initialize();
        console.log("GasDaddy is initialized:", GasDaddy(aliceAddr).isInitialized());

        GasDaddy(aliceAddr).executeCall(address(simpleSBT), abi.encodeWithSignature("mint()"));

        // Verify that Alice received the SBT
        uint256 tokenId = simpleSBT.getTokenId(aliceAddr);
        console.log("Alice received tokenId:", tokenId);
        require(tokenId != 0, "Alice did not receive the SBT");
        // simpleSBT totalSupply
        console.log("SimpleSBT totalSupply:", simpleSBT.totalSupply());
        // simpleSBT balanceOf
        console.log("SimpleSBT balanceOf:", simpleSBT.balanceOf(aliceAddr));

        vm.stopBroadcast();
    }

    function testRemoveDelegation() external {
        uint256 nonceBefore = vm.getNonce(alice.addr);

        // remove delegation
        Vm.SignedDelegation memory signedDelegation =
            vm.signDelegation(address(0), alice.privateKey, uint64(nonceBefore));
        vm.attachDelegation(signedDelegation);

        // assertion
        bytes memory alice_code = alice.addr.code;
        assertEq(alice_code, new bytes(0));
        assertEq(vm.getNonce(alice.addr), nonceBefore);
    }
}
