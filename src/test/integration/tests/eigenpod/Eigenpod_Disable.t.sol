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

    /// Disabling clears any in-flight beacon-chain-ETH withdrawal from the DelegationManager
    /// queue (its shares and delegation were already decremented at queue time), so the
    /// withdrawal can no longer be completed at all. The value is instead recovered by the
    /// owner via withdrawNonRestakedBalance.
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
        uint podBalanceBefore = address(pod).balance;

        // 4. Roll past the withdrawal delay and disable. The queued withdrawal is now
        //    past slashableUntil so disable's per-withdrawal check passes. Disable zeroes REL.
        _rollBlocksForCompleteWithdrawals(withdrawals);

        assertEq(delegationManager.getQueuedWithdrawalRoots(address(staker)).length, 1, "withdrawal queued before disable");

        cheats.prank(address(staker));
        pod.permanentlyDisableRestaking();
        assertTrue(pod.restakingDisabled(), "pod should be disabled");
        assertEq(pod.withdrawableRestakedExecutionLayerGwei(), 0, "REL should be zeroed on disable");

        // The queued withdrawal must have been cleared from the DelegationManager queue by disable.
        assertEq(delegationManager.getQueuedWithdrawalRoots(address(staker)).length, 0, "withdrawal should be cleared on disable");

        IERC20[] memory tokens = new IERC20[](strategies.length);
        for (uint i = 0; i < strategies.length; i++) {
            tokens[i] = strategies[i] == BEACONCHAIN_ETH_STRAT ? NATIVE_ETH : strategies[i].underlyingToken();
        }

        // 5. The withdrawal was removed from the queue, so completing it (either way) reverts as
        //    no-longer-queued.
        cheats.prank(address(staker));
        cheats.expectRevert(IDelegationManagerErrors.WithdrawalNotQueued.selector);
        delegationManager.completeQueuedWithdrawal(withdrawals[0], tokens, true);

        cheats.prank(address(staker));
        cheats.expectRevert(IDelegationManagerErrors.WithdrawalNotQueued.selector);
        delegationManager.completeQueuedWithdrawal(withdrawals[0], tokens, false);

        // 6. The value is recovered via the non-restaked sweep: the entire pod balance
        //    (the exited validator's ETH that was formerly tracked as REL) is sweepable.
        address recipient = cheats.addr(0xD15AB1ED);
        cheats.prank(address(staker));
        pod.withdrawNonRestakedBalance(recipient);
        assertEq(recipient.balance, podBalanceBefore, "owner recovers full pod balance via sweep");
        assertEq(address(pod).balance, 0, "pod fully drained");
    }

    /// Once disabled, the pod owner can request a consolidation whose target is NOT
    /// active in this pod — exactly the external consolidation use case the disable
    /// feature was designed to enable.
    function test_Disabled_AllowsExternalConsolidation(uint24 _rand) public rand(_rand) {
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

/// AVS (EigenLayer) slashing of native ETH has no burn mechanism: the slashed value remains on the
/// beacon chain / in the pod, while share accounting is reduced. Disabling enables external
/// consolidation (which moves validator balance out on the beacon chain) and the non-restaked sweep,
/// either of which could recover the slashed value. To prevent this, disable requires the pod's net
/// restaked beacon-chain balance (REL + last checkpoint's balance + proven creds since) to be <= the
/// owner's slashing-adjusted entitlement. An excess is unrealized AVS slashing and blocks disable.
contract Integration_Eigenpod_Disable_AVSSlashed is IntegrationCheckUtils {
    using ArrayLib for *;

    AVS avs;
    OperatorSet operatorSet;
    User operator;
    AllocateParams allocateParams;

    function _init() internal override {
        _configAssetTypes(HOLDS_ETH);
        _configUserTypes(DEFAULT);
    }

    function _setupSlashableDelegation(User staker, IStrategy[] memory strategies) internal {
        (operator,,) = _newRandomOperator();
        (avs,) = _newRandomAVS();
        staker.delegateTo(operator);
        operatorSet = avs.createOperatorSet(strategies);
        operator.registerForOperatorSet(operatorSet);
        allocateParams = _genAllocation_AllAvailable(operator, operatorSet);
        operator.modifyAllocations(allocateParams);
        _rollBlocksForCompleteAllocation(operator, operatorSet, strategies);
    }

    /// Launder ordering the check closes: AVS-slash while the staker holds live shares, then launder
    /// (undelegate -> complete as shares) so all on-chain share accounting collapses to the reduced
    /// value while the validator's real balance is untouched. Never exit/checkpoint, so REL = 0 and
    /// the slashed value sits on the beacon chain. Disable must REVERT: net restaked balance (the
    /// last checkpoint's proven validator balance) exceeds the laundered entitlement.
    function test_Revert_DisableAfterLaunderingAVSSlash(uint24 _rand) public rand(_rand) {
        (User staker, IStrategy[] memory strategies, uint[] memory tokenBalances) = _newRandomStaker();
        EigenPod pod = staker.pod();
        cheats.assume(tokenBalances[0] >= 64 ether);

        staker.depositIntoEigenlayer(strategies, tokenBalances);
        _setupSlashableDelegation(staker, strategies);

        SlashingParams memory sp = _genSlashing_Half(operator, operatorSet);
        avs.slashOperator(sp);

        // Launder: undelegate (queues all shares) + complete as shares (re-credits the reduced amount).
        Withdrawal[] memory laundered = staker.undelegate();
        _rollBlocksForCompleteWithdrawals(laundered);
        for (uint i = 0; i < laundered.length; i++) {
            staker.completeWithdrawalAsShares(laundered[i]);
        }

        // Re-queue the (reduced) shares so deposit shares hit 0 for the disable precondition.
        int reduced = eigenPodManager.podOwnerDepositShares(address(staker));
        assertGt(reduced, 0, "should have reduced shares re-credited");
        uint[] memory toQueue = new uint[](1);
        toQueue[0] = uint(reduced);
        Withdrawal[] memory requeued = staker.queueWithdrawals(BEACONCHAIN_ETH_STRAT.toArray(), toQueue);
        _rollBlocksForCompleteWithdrawals(requeued);

        assertEq(eigenPodManager.podOwnerDepositShares(address(staker)), 0, "deposit shares cleared");
        assertEq(pod.withdrawableRestakedExecutionLayerGwei(), 0, "REL is 0: slashed value still on beacon chain");

        // Net restaked balance (validator never exited) exceeds laundered entitlement -> revert.
        cheats.prank(address(staker));
        cheats.expectRevert(IEigenPodErrors.PodIsSlashed.selector);
        pod.permanentlyDisableRestaking();
    }

    /// Honest staker delegated to an UNSLASHED operator: net restaked balance equals entitlement,
    /// so disable succeeds.
    function test_DisableWhileDelegatedToUnslashedOperator(uint24 _rand) public rand(_rand) {
        (User staker, IStrategy[] memory strategies, uint[] memory tokenBalances) = _newRandomStaker();
        EigenPod pod = staker.pod();
        cheats.assume(tokenBalances[0] >= 64 ether);

        staker.depositIntoEigenlayer(strategies, tokenBalances);
        uint[] memory depositShares = _calculateExpectedShares(strategies, tokenBalances);
        _setupSlashableDelegation(staker, strategies);

        // No slash. Queue out all shares and disable while still delegated to the unslashed operator.
        Withdrawal[] memory withdrawals = staker.queueWithdrawals(strategies, depositShares);
        _rollBlocksForCompleteWithdrawals(withdrawals);

        cheats.prank(address(staker));
        pod.permanentlyDisableRestaking();
        assertTrue(pod.restakingDisabled(), "unslashed operator: disable should succeed");
    }
}

/// Reconciliation sweep for the net-restaked-vs-entitlement disable check (#8). For honest, UNSLASHED
/// pods across varied orderings, the pod's net restaked balance must equal the owner's entitlement,
/// so disable never falsely reverts PodIsSlashed and the full value remains recoverable. A
/// false-positive (net != entitlement due to a units/accounting bug) would surface as a revert here.
contract Integration_Eigenpod_Disable_Reconcile is IntegrationCheckUtils {
    using ArrayLib for *;

    function _init() internal override {
        _configAssetTypes(HOLDS_ETH);
        _configUserTypes(DEFAULT);
    }

    /// Multiple validators, all exited + checkpointed into REL, then disable.
    function test_Reconcile_MultiValidator_AllExited(uint24 _rand) public rand(_rand) {
        (User staker,,) = _newRandomStaker();
        EigenPod pod = staker.pod();

        (uint40[] memory validators,) = staker.startETH1Validators(3);
        beaconChain.advanceEpoch_NoRewards();
        staker.verifyWithdrawalCredentials(validators);
        staker.startCheckpoint();
        staker.completeCheckpoint();

        // Queue out all shares, exit every validator, checkpoint the exits into REL.
        int shares = eigenPodManager.podOwnerDepositShares(address(staker));
        uint[] memory toQueue = new uint[](1);
        toQueue[0] = uint(shares);
        Withdrawal[] memory w = staker.queueWithdrawals(BEACONCHAIN_ETH_STRAT.toArray(), toQueue);
        staker.exitValidators(validators);
        beaconChain.advanceEpoch_NoRewards();
        staker.startCheckpoint();
        staker.completeCheckpoint();

        uint podBalanceBefore = address(pod).balance;
        _rollBlocksForCompleteWithdrawals(w);

        cheats.prank(address(staker));
        pod.permanentlyDisableRestaking();
        assertTrue(pod.restakingDisabled(), "all-exited multi-validator: disable should succeed");

        address recipient = cheats.addr(0xA11);
        cheats.prank(address(staker));
        pod.withdrawNonRestakedBalance(recipient);
        assertEq(recipient.balance, podBalanceBefore, "full balance recoverable, nothing stranded");
    }

    /// Multiple validators, only SOME exited before disable; the rest remain ACTIVE on the beacon
    /// chain (their balance is in prevBeaconBalanceGwei, not REL). Mixed state must still reconcile.
    function test_Reconcile_MultiValidator_PartialExit(uint24 _rand) public rand(_rand) {
        (User staker,,) = _newRandomStaker();
        EigenPod pod = staker.pod();

        (uint40[] memory validators,) = staker.startETH1Validators(3);
        beaconChain.advanceEpoch_NoRewards();
        staker.verifyWithdrawalCredentials(validators);
        staker.startCheckpoint();
        staker.completeCheckpoint();

        int shares = eigenPodManager.podOwnerDepositShares(address(staker));
        uint[] memory toQueue = new uint[](1);
        toQueue[0] = uint(shares);
        Withdrawal[] memory w = staker.queueWithdrawals(BEACONCHAIN_ETH_STRAT.toArray(), toQueue);

        // Exit only the first validator; checkpoint so REL gains it while the others stay ACTIVE.
        uint40[] memory toExit = new uint40[](1);
        toExit[0] = validators[0];
        staker.exitValidators(toExit);
        beaconChain.advanceEpoch_NoRewards();
        staker.startCheckpoint();
        staker.completeCheckpoint();

        _rollBlocksForCompleteWithdrawals(w);

        cheats.prank(address(staker));
        pod.permanentlyDisableRestaking();
        assertTrue(pod.restakingDisabled(), "partial-exit multi-validator: disable should succeed");
    }

    /// Rewards accrue and are checkpointed AFTER the withdrawal is queued. The reward bumps deposit
    /// shares again (re-blocking disable until re-queued); once re-queued, net restaked must still
    /// equal entitlement.
    function test_Reconcile_RewardsAfterCheckpoint(uint24 _rand) public rand(_rand) {
        (User staker,,) = _newRandomStaker();
        EigenPod pod = staker.pod();

        (uint40[] memory validators,) = staker.startETH1Validators(2);
        beaconChain.advanceEpoch_NoRewards();
        staker.verifyWithdrawalCredentials(validators);
        staker.startCheckpoint();
        staker.completeCheckpoint();

        // Queue all current shares.
        int shares = eigenPodManager.podOwnerDepositShares(address(staker));
        uint[] memory toQueue = new uint[](1);
        toQueue[0] = uint(shares);
        Withdrawal[] memory first = staker.queueWithdrawals(BEACONCHAIN_ETH_STRAT.toArray(), toQueue);

        // Rewards accrue; checkpoint credits them as fresh deposit shares.
        beaconChain.advanceEpoch();
        staker.startCheckpoint();
        staker.completeCheckpoint();

        // Re-queue the reward shares so deposit shares hit 0.
        Withdrawal[] memory second;
        int rewardShares = eigenPodManager.podOwnerDepositShares(address(staker));
        if (rewardShares > 0) {
            uint[] memory rq = new uint[](1);
            rq[0] = uint(rewardShares);
            second = staker.queueWithdrawals(BEACONCHAIN_ETH_STRAT.toArray(), rq);
        }

        _rollBlocksForCompleteWithdrawals(first);
        if (second.length > 0) _rollBlocksForCompleteWithdrawals(second);

        cheats.prank(address(staker));
        pod.permanentlyDisableRestaking();
        assertTrue(pod.restakingDisabled(), "rewards-after-checkpoint: disable should succeed");
    }
}
