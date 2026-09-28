// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";

contract LaunchTokenTest is Test {
    LaunchToken internal token;
    address internal deployer = makeAddr("deployer");

    function setUp() public {
        vm.prank(deployer);
        token = new LaunchToken();
    }

    function test_supplyMintedToDeployer() public view {
        assertEq(token.totalSupply(), 1_000_000_000e18);
        assertEq(token.totalSupply(), 10 ** 27);
        assertEq(token.balanceOf(deployer), token.totalSupply());
        assertEq(token.decimals(), 18);
        assertEq(token.name(), "Pacts");
        assertEq(token.symbol(), "PACT");
    }

    function test_transferMovesExactAmount() public {
        address to = makeAddr("to");
        vm.prank(deployer);
        assertTrue(token.transfer(to, 123e18));
        assertEq(token.balanceOf(to), 123e18);
        assertEq(token.balanceOf(deployer), token.totalSupply() - 123e18);
        assertEq(token.totalSupply(), 10 ** 27);
    }

    function test_noMintFunction() public {
        (bool ok,) = address(token).call(abi.encodeWithSignature("mint(address,uint256)", deployer, 1));
        assertFalse(ok);
        assertEq(token.totalSupply(), 10 ** 27);
    }

    function testFuzz_transferConservesSupply(address to, uint256 amount) public {
        vm.assume(to != address(0) && to != deployer);
        amount = bound(amount, 0, token.totalSupply());
        vm.prank(deployer);
        token.transfer(to, amount);
        assertEq(token.balanceOf(to) + token.balanceOf(deployer), token.totalSupply());
    }
}
