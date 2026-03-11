import 'dart:async';
import 'package:flutter/material.dart';
import 'package:eden/services/p2p_service.dart';
import 'package:eden/localization/lgpkg.dart';

const Color kEdenSurface = Color(0xFF1F1F1F);
const Color kEdenOrange = Color.fromARGB(255, 255, 102, 0);
const Color kEdenTextDim = Color(0xFFAAAAAA);
const Color kEdenBorder = Color(0xFF333333);

class ValidatorDashboard extends StatefulWidget {
  final String myPeerID;
  final P2PService p2pService;

  const ValidatorDashboard({
    super.key,
    required this.myPeerID,
    required this.p2pService,
  });

  @override
  State<ValidatorDashboard> createState() => _ValidatorDashboardState();
}

class _ValidatorDashboardState extends State<ValidatorDashboard> {
  final Lgpkg _lgpkg = Lgpkg();
  
  Map<String, dynamic> _metrics = {
    "demos_parsed": 0,
    "edn_earned": 0.0,
    "accuracy": 0.0,
    "staked_edn": 0.0,
  };
  
  bool _isLoading = true;
  Timer? _pollingTimer;

  @override
  void initState() {
    super.initState();
    _fetchMetrics();
    _pollingTimer = Timer.periodic(const Duration(seconds: 5), (_) => _fetchMetrics());
  }

  @override
  void dispose() {
    _pollingTimer?.cancel();
    super.dispose();
  }

  Future<void> _fetchMetrics() async {
    if (widget.myPeerID.isEmpty) return;
    
    final data = await widget.p2pService.getValidatorMetrics(widget.myPeerID);
    if (mounted && data.isNotEmpty) {
      setState(() {
        _metrics = data;
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator(color: kEdenOrange));
    }

    double accuracy = (_metrics["accuracy"] ?? 0.0).toDouble();
    double staked = (_metrics["staked_edn"] ?? 0.0).toDouble();
    double earned = (_metrics["edn_earned"] ?? 0.0).toDouble();
    int parsed = _metrics["demos_parsed"] ?? 0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              _lgpkg.get("ValidatorDashboard") ?? "TRIBUNAL VALIDATOR NODE", 
              style: const TextStyle(color: Colors.white, fontSize: 24, fontFamily: "Oswald", fontWeight: FontWeight.bold)
            ),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: kEdenOrange,
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
              ),
              icon: const Icon(Icons.security),
              label: Text(_lgpkg.get("ManageStake") ?? "MANAGE STAKE", style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
              onPressed: () {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text("Stake management interface coming soon."))
                );
              },
            )
          ],
        ),
        const SizedBox(height: 24),
        
        Row(
          children: [
            Expanded(child: _buildMetricCard("TOTAL STAKED", "${staked.toStringAsFixed(2)} EDN", Icons.lock, Colors.blueAccent)),
            const SizedBox(width: 16),
            Expanded(child: _buildMetricCard("EDN EARNED", "+${earned.toStringAsFixed(2)}", Icons.account_balance_wallet, Colors.green)),
            const SizedBox(width: 16),
            Expanded(child: _buildMetricCard("DEMOS PARSED", "$parsed", Icons.find_in_page, kEdenOrange)),
            const SizedBox(width: 16),
            Expanded(child: _buildMetricCard("VOTING ACCURACY", "${accuracy.toStringAsFixed(1)}%", Icons.gavel, _getAccuracyColor(accuracy))),
          ],
        ),
        const SizedBox(height: 24),
        
        Expanded(
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(32),
            decoration: BoxDecoration(
              color: kEdenSurface,
              border: Border.all(color: staked > 0 ? Colors.green.withValues(alpha: 0.5) : kEdenBorder, width: staked > 0 ? 2 : 1),
              borderRadius: BorderRadius.circular(4),
              boxShadow: staked > 0 ? [BoxShadow(color: Colors.green.withValues(alpha: 0.05), blurRadius: 20, spreadRadius: 5)] : [],
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  staked > 0 ? Icons.monitor_heart : Icons.gavel_outlined, 
                  size: 80, 
                  color: staked > 0 ? Colors.green.withValues(alpha: 0.8) : kEdenTextDim.withValues(alpha: 0.2)
                ),
                const SizedBox(height: 24),
                Text(
                  staked > 0 ? "NODE ACTIVE & LISTENING" : "NODE INACTIVE",
                  style: TextStyle(
                    color: staked > 0 ? Colors.green : Colors.grey, 
                    fontSize: 24, 
                    fontFamily: "Oswald", 
                    fontWeight: FontWeight.bold,
                    letterSpacing: 2
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  staked > 0 
                    ? "Your node is currently participating in consensus and parsing Tribunal demos." 
                    : "Stake EDN to activate your node, parse demos, and earn consensus rewards.",
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: kEdenTextDim, fontSize: 14),
                ),
              ],
            ),
          ),
        )
      ],
    );
  }

  Color _getAccuracyColor(double acc) {
    if (acc == 0) return Colors.grey;
    if (acc >= 90) return Colors.green;
    if (acc >= 75) return Colors.yellow;
    return Colors.redAccent;
  }

  Widget _buildMetricCard(String title, String value, IconData icon, Color highlightColor) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: kEdenSurface,
        border: Border.all(color: kEdenBorder),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: highlightColor, size: 20),
              const SizedBox(width: 8),
              Text(title, style: const TextStyle(color: kEdenTextDim, fontSize: 12, fontWeight: FontWeight.bold, letterSpacing: 1.2)),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            value, 
            style: const TextStyle(color: Colors.white, fontSize: 32, fontFamily: "Oswald", fontWeight: FontWeight.bold)
          ),
        ],
      ),
    );
  }
}