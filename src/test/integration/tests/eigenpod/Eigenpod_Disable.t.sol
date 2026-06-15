// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import "src/test/integration/IntegrationChecks.t.sol";
import "src/test/integration/users/User.t.sol";

contract Integration_Eigenpod_Disable is IntegrationCheckUtils {
    using ArrayLib for *;

    function _init() internal override {
        _configAssetTypes(HOLDS_ETH);
        _configUserTypes(DEFAULT);
    }

    /// End-to-end exercise of the irreversible disable toggle:
    /// 1. Verify validator credentials, picking up shares
    /// 2. Queue a full withdrawal
    /// 3. Roll past the withdrawal delay and complete as tokens (auto-exits + checkpoints)
    /// 4. Permanently disable restaking
    /// 5. Send fresh ETH to the pod and sweep it via withdrawNonRestakedBalance
    /// 6. Confirm post-disable invariants:
    ///    - re-disable reverts AlreadyDisabled
    ///    - verifyWithdrawalCredentials on a fresh validator reverts RestakingDisabled
    ///    - startCheckpoint reverts RestakingDisabled
    function test_VerifyWC_Queue_Complete_Disable_Sweep(uint24 _rand) public rand(_rand) {
        (User staker, IStrategy[] memory strategies, uint[] memory tokenBalances) = _newRandomStaker();
        EigenPod pod = staker.pod();

        // 1. Stake on the beacon chain and verify withdrawal credentials.
        staker.depositIntoEigenlayer(strategies, tokenBalances);
        uint[] memory shares = _calculateExpectedShares(strategies, tokenBalances);
        check_Deposit_State(staker, strategies, shares);

        // 2. Queue a full withdrawal of all beacon-chain ETH shares.
        Withdrawal[] memory withdrawals = staker.queueWithdrawals(strategies, shares);

        // 3. Roll past the withdrawal delay and complete as tokens. The User helper
        //    auto-exits validators and checkpoints them as part of completion.
        _rollBlocksForCompleteWithdrawals(withdrawals);
        for (uint i = 0; i < withdrawals.length; i++) {
            staker.completeWithdrawalAsTokens(withdrawals[i]);
        }

        // After completion, the staker has no positive deposit shares and the only
        // queued withdrawals on file are past their delay.
        assertEq(eigenPodManager.podOwnerDepositShares(address(staker)), 0, "deposit shares should be cleared");

        // 4. Permanently disable restaking.
        cheats.prank(address(staker));
        pod.permanentlyDisableRestaking();
        assertTrue(pod.restakingDisabled(), "pod should be disabled");

        // 5. Drop some fresh ETH on the pod and sweep it.
        uint64 relGwei = pod.withdrawableRestakedExecutionLayerGwei();
        uint relWei = uint(relGwei) * 1 gwei;
        cheats.deal(address(this), 3 ether);
        (bool ok,) = address(pod).call{value: 3 ether}("");
        assertTrue(ok, "send to pod failed");

        address recipient = cheats.addr(0xFEED);
        uint preBalance = address(pod).balance;
        cheats.prank(address(staker));
        pod.withdrawNonRestakedBalance(recipient);

        assertEq(address(pod).balance, relWei, "REL portion must remain after sweep");
        assertEq(recipient.balance, preBalance - relWei, "recipient receives surplus only");
        assertEq(pod.withdrawableRestakedExecutionLayerGwei(), relGwei, "REL accounting unchanged by sweep");

        // 6a. Re-disabling reverts.
        cheats.prank(address(staker));
        cheats.expectRevert(IEigenPodErrors.AlreadyDisabled.selector);
        pod.permanentlyDisableRestaking();

        // 6b. Restarting share creation reverts. Spin up a new validator pointing
        // at the disabled pod and try to verify its credentials.
        cheats.deal(address(staker), 32 ether);
        (uint40[] memory newValidators,) = staker.startETH1Validators(1);
        beaconChain.advanceEpoch_NoRewards();

        CredentialProofs memory proofs = beaconChain.getCredentialProofs(newValidators);
        cheats.prank(address(staker));
        cheats.expectRevert(IEigenPodErrors.RestakingDisabled.selector);
        pod.verifyWithdrawalCredentials({
            beaconTimestamp: proofs.beaconTimestamp,
            stateRootProof: proofs.stateRootProof,
            validatorIndices: newValidators,
            validatorFieldsProofs: proofs.validatorFieldsProofs,
            validatorFields: proofs.validatorFields
        });

        // 6c. startCheckpoint reverts too — the disable guard lives in `_startCheckpoint`.
        cheats.prank(address(staker));
        cheats.expectRevert(IEigenPodErrors.RestakingDisabled.selector);
        pod.startCheckpoint(false);
    }

    /// Disabling does NOT block in-flight withdrawal completions. As long as REL is
    /// credited before the disable (which it must be, since `startCheckpoint` is locked
    /// once disabled), the staker can complete a queued withdrawal as tokens after the
    /// disable lands.
    function test_Queue_Exit_Checkpoint_Disable_Complete(uint24 _rand) public rand(_rand) {
        (User staker, IStrategy[] memory strategies, uint[] memory tokenBalances) = _newRandomStaker();
        EigenPod pod = staker.pod();

        // 1. Stake + verify withdrawal credentials.
        staker.depositIntoEigenlayer(strategies, tokenBalances);
        uint[] memory shares = _calculateExpectedShares(strategies, tokenBalances);

        // 2. Queue a full withdrawal — deposit shares drop to 0 immediately on queue,
        //    not on completion. This is what unblocks the disable precondition.
        Withdrawal[] memory withdrawals = staker.queueWithdrawals(strategies, shares);
        assertEq(eigenPodManager.podOwnerDepositShares(address(staker)), 0, "queue should clear deposit shares");

        // 3. Exit the validator and credit its balance into REL via a checkpoint.
        //    This MUST happen before disable; afterwards startCheckpoint reverts.
        uint40[] memory active = staker.getActiveValidators();
        staker.exitValidators(active);
        beaconChain.advanceEpoch_NoRewards();
        staker.startCheckpoint();
        staker.completeCheckpoint();

        uint64 relGwei = pod.withdrawableRestakedExecutionLayerGwei();
        assertGt(relGwei, 0, "REL should be credited after exit checkpoint");

        // 4. Roll past the withdrawal delay and disable. The queued withdrawal is now
        //    past slashableUntil so disable's per-withdrawal check passes.
        _rollBlocksForCompleteWithdrawals(withdrawals);

        cheats.prank(address(staker));
        pod.permanentlyDisableRestaking();
        assertTrue(pod.restakingDisabled(), "pod should be disabled");

        // 5. Complete the withdrawal directly via the DelegationManager. This bypasses
        //    the User helper (which would try to start a checkpoint and revert). The
        //    DM path calls EigenPodManager.withdrawSharesAsTokens → EigenPod.withdrawRestakedBeaconChainETH,
        //    which is NOT gated by the disable flag and pays out from REL.
        IERC20[] memory tokens = new IERC20[](strategies.length);
        for (uint i = 0; i < strategies.length; i++) {
            tokens[i] = strategies[i] == BEACONCHAIN_ETH_STRAT ? NATIVE_ETH : strategies[i].underlyingToken();
        }

        uint stakerBalanceBefore = address(staker).balance;
        cheats.prank(address(staker));
        delegationManager.completeQueuedWithdrawal(withdrawals[0], tokens, true);

        // The staker should have received native ETH equal to the previously-credited REL.
        uint expected = uint(relGwei) * 1 gwei;
        assertEq(
            address(staker).balance - stakerBalanceBefore,
            expected,
            "staker should receive REL-worth of ETH on completion"
        );
        assertEq(pod.withdrawableRestakedExecutionLayerGwei(), 0, "REL should be drained");
    }

    /// Once disabled, the pod owner can request a consolidation whose target is NOT
    /// active in this pod — exactly the cross-pod consolidation use case the disable
    /// feature was designed to enable.
    function test_Disabled_AllowsCrossPodConsolidation(uint24 _rand) public rand(_rand) {
        (User source, IStrategy[] memory strategies, uint[] memory tokenBalances) = _newRandomStaker();
        EigenPod sourcePod = source.pod();

        // Source pod: stake → verify → queue → complete → disable
        source.depositIntoEigenlayer(strategies, tokenBalances);
        uint[] memory shares = _calculateExpectedShares(strategies, tokenBalances);

        Withdrawal[] memory withdrawals = source.queueWithdrawals(strategies, shares);
        _rollBlocksForCompleteWithdrawals(withdrawals);
        for (uint i = 0; i < withdrawals.length; i++) {
            source.completeWithdrawalAsTokens(withdrawals[i]);
        }
        assertEq(eigenPodManager.podOwnerDepositShares(address(source)), 0, "deposit shares should be cleared");

        cheats.prank(address(source));
        sourcePod.permanentlyDisableRestaking();

        // Pre-disable, requestConsolidation requires the target validator to be ACTIVE in
        // the source pod. We verify the post-disable exception by pointing at validator
        // indices the source pod has never seen.
        bytes memory srcPubkey = beaconChain.pubkey(uint40(1));
        bytes memory targetPubkey = beaconChain.pubkey(uint40(2));

        ConsolidationRequest[] memory cReqs = new ConsolidationRequest[](1);
        cReqs[0] = ConsolidationRequest({srcPubkey: srcPubkey, targetPubkey: targetPubkey});

        uint fee = sourcePod.getConsolidationRequestFee();
        cheats.deal(address(source), address(source).balance + fee);
        cheats.prank(address(source));
        sourcePod.requestConsolidation{value: fee}(cReqs);
    }
}
