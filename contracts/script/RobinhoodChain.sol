// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title RobinhoodChain
/// @notice Robinhood Chain mainnet (chain id 4663) addresses used by the deploy script.
///         Every address below was read from an official source and checked on-chain (code present,
///         symbol/decimals match). Keep in sync with /config/chains.ts.
///
/// Sources:
///  - Network / USDG / WETH:  https://docs.robinhood.com/chain/connecting , https://docs.robinhood.com/chain/contracts
///  - Stock tokens:           https://api.robinhood.com/rhj/assets  (official Stock Token API,
///                            https://docs.robinhood.com/chain/stock-token-apis)
///  - Chainlink feeds:        https://docs.chain.link/data-feeds/price-feeds/addresses?network=robinhood
///                            (data: https://reference-data-directory.vercel.app/feeds-robinhood-mainnet.json)
///  - Uniswap v3:             https://developers.uniswap.org/docs/protocols/v3/deployments/v3-robinhood-chain-deployments
library RobinhoodChain {
    uint256 internal constant CHAIN_ID = 4663;

    // Stablecoin (Global Dollar, 6 decimals) and its Chainlink USD feed
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address internal constant USDG_USD_FEED = 0x61B7e5650328764B076A108EFF5fa7282a1B9aD2;

    // Uniswap v3
    address internal constant UNIV3_FACTORY = 0x1f7d7550B1b028f7571E69A784071F0205FD2EfA;
    address internal constant UNIV3_SWAP_ROUTER02 = 0xCaf681a66D020601342297493863E78C959E5cb2;
    address internal constant UNIV3_QUOTER_V2 = 0x33e885eD0Ec9bF04EcfB19341582aADCb4c8A9E7;

    // Stock tokens (18 decimals) and their Chainlink feeds (8 decimals, multiplier-adjusted, 24/5)
    address internal constant AAPL = 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9;
    address internal constant AAPL_FEED = 0x6B22A786bAa607d76728168703a39Ea9C99f2cD0;
    address internal constant MSFT = 0xe93237C50D904957Cf27E7B1133b510C669c2e74;
    address internal constant MSFT_FEED = 0x45C3C877C15E6BA2EBB19eA114Ea508d14C1Af2E;
    address internal constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    address internal constant NVDA_FEED = 0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15;
    address internal constant TSLA = 0x322F0929c4625eD5bAd873c95208D54E1c003b2d;
    address internal constant TSLA_FEED = 0x4A1166a659A55625345e9515b32adECea5547C38;
    address internal constant AMZN = 0x12f190a9F9d7D37a250758b26824B97CE941bF54;
    address internal constant AMZN_FEED = 0xD5a1508ceD74c084eBf3cBe853e2C968fB2a651C;
    address internal constant GOOGL = 0x2e0847E8910a9732eB3fb1bb4b70a580ADAD4FE3;
    address internal constant GOOGL_FEED = 0xF6f373a037c30F0e5010d854385cA89185AE638b;
    address internal constant META = 0xc0D6457C16Cc70d6790Dd43521C899C87ce02f35;
    address internal constant META_FEED = 0x7C38C00C30BEe9378381E7B6135d7283356D71b1;
    address internal constant COIN = 0x6330D8C3178a418788dF01a47479c0ce7CCF450b;
    address internal constant COIN_FEED = 0xA3a468A452940B7D6b69991207B508c609a98Ef2;
    address internal constant SPY = 0x117cc2133c37B721F49dE2A7a74833232B3B4C0C;
    address internal constant SPY_FEED = 0x319724394D3A0e3669269846abE664Cd621f9f6A;
    address internal constant QQQ = 0xD5f3879160bc7c32ebb4dC785F8a4F505888de68;
    address internal constant QQQ_FEED = 0x80901d846d5D7B030F26B480776EE3b29374C2ae;

    struct Stock {
        string symbol;
        address token;
        address feed;
    }

    function stocks() internal pure returns (Stock[] memory s) {
        s = new Stock[](10);
        s[0] = Stock("AAPL", AAPL, AAPL_FEED);
        s[1] = Stock("MSFT", MSFT, MSFT_FEED);
        s[2] = Stock("NVDA", NVDA, NVDA_FEED);
        s[3] = Stock("TSLA", TSLA, TSLA_FEED);
        s[4] = Stock("AMZN", AMZN, AMZN_FEED);
        s[5] = Stock("GOOGL", GOOGL, GOOGL_FEED);
        s[6] = Stock("META", META, META_FEED);
        s[7] = Stock("COIN", COIN, COIN_FEED);
        s[8] = Stock("SPY", SPY, SPY_FEED);
        s[9] = Stock("QQQ", QQQ, QQQ_FEED);
    }

    /// @notice NYSE full-day closures (https://www.nyse.com/markets/hours-calendars), as [year, month, day].
    ///         Early 1 p.m. closes are not modelled (conversion simply also runs in the shortened session).
    function nyseHolidays() internal pure returns (uint16[3][] memory h) {
        h = new uint16[3][](20);
        // 2026
        h[0] = [uint16(2026), 1, 1];
        h[1] = [uint16(2026), 1, 19];
        h[2] = [uint16(2026), 2, 16];
        h[3] = [uint16(2026), 4, 3];
        h[4] = [uint16(2026), 5, 25];
        h[5] = [uint16(2026), 6, 19];
        h[6] = [uint16(2026), 7, 3];
        h[7] = [uint16(2026), 9, 7];
        h[8] = [uint16(2026), 11, 26];
        h[9] = [uint16(2026), 12, 25];
        // 2027
        h[10] = [uint16(2027), 1, 1];
        h[11] = [uint16(2027), 1, 18];
        h[12] = [uint16(2027), 2, 15];
        h[13] = [uint16(2027), 3, 26];
        h[14] = [uint16(2027), 5, 31];
        h[15] = [uint16(2027), 6, 18];
        h[16] = [uint16(2027), 7, 5];
        h[17] = [uint16(2027), 9, 6];
        h[18] = [uint16(2027), 11, 25];
        h[19] = [uint16(2027), 12, 24];
    }
}
