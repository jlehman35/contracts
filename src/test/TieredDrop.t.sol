// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.0;

import "./utils/BaseTest.sol";
import "contracts/lib/TWStrings.sol";

import { TieredDrop } from "contracts/tiered-drop/TieredDrop.sol";
import { TWProxy } from "contracts/TWProxy.sol";

contract TieredDropTest is BaseTest {
    using TWStrings for uint256;

    TieredDrop public tieredDrop;

    address internal dropAdmin;
    address internal claimer;

    // Signature params
    address internal deployerSigner;
    bytes32 internal typehashGenericRequest;
    bytes32 internal nameHash;
    bytes32 internal versionHash;
    bytes32 internal typehashEip712;
    bytes32 internal domainSeparator;

    // Lazy mint variables
    uint256 internal quantityTier1 = 10;
    string internal tier1 = "tier1";
    string internal baseURITier1 = "baseURI1/";
    string internal placeholderURITier1 = "placeholderURI1/";
    bytes internal keyTier1 = "tier1_key";

    uint256 internal quantityTier2 = 20;
    string internal tier2 = "tier2";
    string internal baseURITier2 = "baseURI2/";
    string internal placeholderURITier2 = "placeholderURI2/";
    bytes internal keyTier2 = "tier2_key";

    uint256 internal quantityTier3 = 30;
    string internal tier3 = "tier3";
    string internal baseURITier3 = "baseURI3/";
    string internal placeholderURITier3 = "placeholderURI3/";
    bytes internal keyTier3 = "tier3_key";

    function setUp() public override {
        super.setUp();

        dropAdmin = getActor(1);
        claimer = getActor(2);

        // Deploy implementation.
        address tieredDropImpl = address(new TieredDrop());

        // Deploy proxy pointing to implementaion.
        vm.prank(dropAdmin);
        tieredDrop = TieredDrop(
            address(
                new TWProxy(
                    tieredDropImpl,
                    abi.encodeCall(
                        TieredDrop.initialize,
                        (dropAdmin, "Tiered Drop", "TD", "ipfs://", new address[](0), dropAdmin, dropAdmin, 0)
                    )
                )
            )
        );

        // ====== signature params

        deployerSigner = signer;
        vm.prank(dropAdmin);
        tieredDrop.grantRole(keccak256("MINTER_ROLE"), deployerSigner);

        typehashGenericRequest = keccak256(
            "GenericRequest(uint128 validityStartTimestamp,uint128 validityEndTimestamp,bytes32 uid,bytes data)"
        );
        nameHash = keccak256(bytes("SignatureAction"));
        versionHash = keccak256(bytes("1"));
        typehashEip712 = keccak256(
            "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
        );
        domainSeparator = keccak256(
            abi.encode(typehashEip712, nameHash, versionHash, block.chainid, address(tieredDrop))
        );

        // ======
    }

    TieredDrop.GenericRequest internal claimRequest;
    bytes internal claimSignature;

    function _setupClaimSignature(string[] memory _orderedTiers, uint256 _totalQuantity) private {
        claimRequest.validityStartTimestamp = 1000;
        claimRequest.validityEndTimestamp = 2000;
        claimRequest.uid = bytes32("UID");
        claimRequest.data = abi.encode(
            _orderedTiers,
            claimer,
            address(0),
            0,
            dropAdmin,
            _totalQuantity,
            0,
            NATIVE_TOKEN
        );

        bytes memory encodedRequest = abi.encode(
            typehashGenericRequest,
            claimRequest.validityStartTimestamp,
            claimRequest.validityEndTimestamp,
            claimRequest.uid,
            keccak256(bytes(claimRequest.data))
        );

        bytes32 structHash = keccak256(encodedRequest);
        bytes32 typedDataHash = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, typedDataHash);
        claimSignature = abi.encodePacked(r, s, v);
    }

    function test_flow() public {
        // Lazy mint tokens: 3 different tiers
        vm.startPrank(dropAdmin);

        // Tier 1: tokenIds assigned 0 -> 10 non-inclusive.
        tieredDrop.lazyMint(quantityTier1, baseURITier1, tier1, "");
        // Tier 2: tokenIds assigned 10 -> 30 non-inclusive.
        tieredDrop.lazyMint(quantityTier2, baseURITier2, tier2, "");
        // Tier 3: tokenIds assigned 30 -> 60 non-inclusive.
        tieredDrop.lazyMint(quantityTier3, baseURITier3, tier3, "");

        vm.stopPrank();

        /**
         *  Claim tokens.
         *      - Order of priority: [tier2, tier1]
         *      - Total quantity: 25. [20 from tier2, 5 from tier1]
         */

        string[] memory tiers = new string[](2);
        tiers[0] = tier2;
        tiers[1] = tier1;

        uint256 claimQuantity = 25;

        _setupClaimSignature(tiers, claimQuantity);

        assertEq(tieredDrop.hasRole(keccak256("MINTER_ROLE"), deployerSigner), true);

        vm.warp(claimRequest.validityStartTimestamp);
        vm.prank(claimer);
        tieredDrop.claimWithSignature(claimRequest, claimSignature);

        /**
         *  Check token URIs for tokens of tiers:
         *      - Tier 2: token IDs 0 -> 19 mapped one-to-one to metadata IDs 10 -> 29
         *      - Tier 1: token IDs 20 -> 24 mapped one-to-one to metadata IDs 0 -> 4
         */

        uint256 tier2Id = 10;
        uint256 tier1Id = 0;

        for (uint256 i = 0; i < claimQuantity; i += 1) {
            // console.log(i);
            if (i < 20) {
                assertEq(tieredDrop.tokenURI(i), string(abi.encodePacked(baseURITier2, tier2Id.toString())));
                tier2Id += 1;
            } else {
                assertEq(tieredDrop.tokenURI(i), string(abi.encodePacked(baseURITier1, tier1Id.toString())));
                tier1Id += 1;
            }
        }
    }

    function _getProvenanceHash(string memory _revealURI, bytes memory _key) private view returns (bytes32) {
        return keccak256(abi.encodePacked(_revealURI, _key, block.chainid));
    }

    function test_flow_randomOnReveal() public {
        // Lazy mint tokens: 3 different tiers: with delayed reveal
        bytes memory encryptedURITier1 = tieredDrop.encryptDecrypt(bytes(baseURITier1), keyTier1);
        bytes memory encryptedURITier2 = tieredDrop.encryptDecrypt(bytes(baseURITier2), keyTier2);
        bytes memory encryptedURITier3 = tieredDrop.encryptDecrypt(bytes(baseURITier3), keyTier3);

        vm.startPrank(dropAdmin);

        // Tier 1: tokenIds assigned 0 -> 10 non-inclusive.
        tieredDrop.lazyMint(
            quantityTier1,
            placeholderURITier1,
            tier1,
            abi.encode(encryptedURITier1, _getProvenanceHash(baseURITier1, keyTier1))
        );
        // Tier 2: tokenIds assigned 10 -> 30 non-inclusive.
        tieredDrop.lazyMint(
            quantityTier2,
            placeholderURITier2,
            tier2,
            abi.encode(encryptedURITier2, _getProvenanceHash(baseURITier2, keyTier2))
        );
        // Tier 3: tokenIds assigned 30 -> 60 non-inclusive.
        tieredDrop.lazyMint(
            quantityTier3,
            placeholderURITier3,
            tier3,
            abi.encode(encryptedURITier3, _getProvenanceHash(baseURITier3, keyTier3))
        );

        vm.stopPrank();

        /**
         *  Claim tokens.
         *      - Order of priority: [tier2, tier1]
         *      - Total quantity: 25. [20 from tier2, 5 from tier1]
         */

        string[] memory tiers = new string[](2);
        tiers[0] = tier2;
        tiers[1] = tier1;

        uint256 claimQuantity = 25;

        _setupClaimSignature(tiers, claimQuantity);

        assertEq(tieredDrop.hasRole(keccak256("MINTER_ROLE"), deployerSigner), true);

        vm.warp(claimRequest.validityStartTimestamp);
        vm.prank(claimer);
        tieredDrop.claimWithSignature(claimRequest, claimSignature);

        /**
         *  Check token URIs for tokens of tiers:
         *      - Tier 2: token IDs 0 -> 19 mapped one-to-one to metadata IDs 10 -> 29
         *      - Tier 1: token IDs 20 -> 24 mapped one-to-one to metadata IDs 0 -> 4
         */

        uint256 tier2Id = 10;
        uint256 tier1Id = 0;

        for (uint256 i = 0; i < claimQuantity; i += 1) {
            // console.log(i);
            if (i < 20) {
                assertEq(tieredDrop.tokenURI(i), string(abi.encodePacked(placeholderURITier2, uint256(0).toString())));
                tier2Id += 1;
            } else {
                assertEq(tieredDrop.tokenURI(i), string(abi.encodePacked(placeholderURITier1, uint256(0).toString())));
                tier1Id += 1;
            }
        }

        // Reveal tokens.
        vm.startPrank(dropAdmin);
        tieredDrop.reveal(0, keyTier1);
        tieredDrop.reveal(1, keyTier2);
        tieredDrop.reveal(2, keyTier3);

        // for (uint256 i = 0; i < claimQuantity; i += 1) {
        //     console.log(i);
        //     if (i < 20) {
        //         console.log(i, tieredDrop.tokenURI(i));
        //         tier2Id += 1;
        //     } else {
        //         console.log(i, tieredDrop.tokenURI(i));
        //         tier1Id += 1;
        //     }
        // }
    }
}