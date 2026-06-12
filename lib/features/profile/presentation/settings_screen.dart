import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_typography.dart';

/// Local-only precision options for the location preference toggle.
enum _LocationPrecision {
  /// Default: rider profile picks the precision based on assignment state.
  auto,

  /// Always-high precision (heavier on battery).
  high,
}

/// Settings screen with notification preferences, help link, and an app
/// version footer.
///
/// Toggles are stub state held locally for the MVP — they will be wired
/// to a persistent store in a follow-up. The notifications toggle and
/// the location precision selector are surfaced here so the rider can
/// see where these controls will live.
class SettingsScreen extends StatefulWidget {
  /// Const constructor.
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _notificationsEnabled = true;
  bool _orderAlertsEnabled = true;
  _LocationPrecision _precision = _LocationPrecision.auto;
  String _appVersion = '0.1.0 (1)';

  @override
  void initState() {
    super.initState();
    _loadVersion();
  }

  Future<void> _loadVersion() async {
    try {
      final PackageInfo info = await PackageInfo.fromPlatform();
      if (mounted) {
        setState(() {
          _appVersion = '${info.version} (${info.buildNumber})';
        });
      }
    } catch (_) {
      // Keep the static fallback if PackageInfo fails.
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.offWhite,
      appBar: AppBar(
        backgroundColor: AppColors.white,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: AppColors.charcoal),
          onPressed: () => context.pop(),
        ),
        title: Text(
          'Settings',
          style: AppTypography.heading.copyWith(color: AppColors.charcoal),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          const _SectionHeader(label: 'NOTIFICATIONS'),
          const SizedBox(height: 8),
          _ToggleRow(
            icon: Icons.notifications_outlined,
            label: 'Push notifications',
            value: _notificationsEnabled,
            onChanged: (bool v) => setState(() => _notificationsEnabled = v),
          ),
          const SizedBox(height: 8),
          _ToggleRow(
            icon: Icons.delivery_dining_outlined,
            label: 'Order alerts',
            value: _orderAlertsEnabled,
            onChanged: (bool v) => setState(() => _orderAlertsEnabled = v),
          ),
          const SizedBox(height: 24),

          const _SectionHeader(label: 'LOCATION'),
          const SizedBox(height: 8),
          _ToggleRow(
            icon: Icons.gps_fixed,
            label: 'High-precision location',
            subtitle: _precision == _LocationPrecision.high
                ? 'Always high — heavier on battery'
                : 'Auto — battery friendly',
            value: _precision == _LocationPrecision.high,
            onChanged: (bool v) => setState(
              () => _precision =
                  v ? _LocationPrecision.high : _LocationPrecision.auto,
            ),
          ),
          const SizedBox(height: 24),

          const _SectionHeader(label: 'SUPPORT'),
          const SizedBox(height: 8),
          _TapRow(
            icon: Icons.help_outline,
            label: 'Help & support',
            onTap: () {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Help coming soon')),
              );
            },
          ),
          const SizedBox(height: 24),

          const _SectionHeader(label: 'ABOUT'),
          const SizedBox(height: 8),
          _InfoTile(
            icon: Icons.info_outline,
            label: 'App version',
            value: _appVersion,
          ),
          const SizedBox(height: 24),
          Center(
            child: Text(
              'Bakaloo Rider · v$_appVersion',
              style: AppTypography.micro.copyWith(color: AppColors.muted),
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

/// Section header label.
class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Text(
        label,
        style: AppTypography.micro.copyWith(color: AppColors.muted),
      ),
    );
  }
}

/// A toggle row for boolean settings.
class _ToggleRow extends StatelessWidget {
  const _ToggleRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.onChanged,
    this.subtitle,
  });

  final IconData icon;
  final String label;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: <Widget>[
          Icon(icon, size: 22, color: AppColors.charcoal),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  label,
                  style: AppTypography.body.copyWith(color: AppColors.charcoal),
                ),
                if (subtitle != null) ...<Widget>[
                  const SizedBox(height: 2),
                  Text(
                    subtitle!,
                    style:
                        AppTypography.micro.copyWith(color: AppColors.muted),
                  ),
                ],
              ],
            ),
          ),
          Switch(
            value: value,
            onChanged: onChanged,
            activeThumbColor: AppColors.black,
          ),
        ],
      ),
    );
  }
}

/// A tappable row for navigation/action items.
class _TapRow extends StatelessWidget {
  const _TapRow({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.white,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppColors.border),
          ),
          child: Row(
            children: <Widget>[
              Icon(icon, size: 22, color: AppColors.charcoal),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  label,
                  style: AppTypography.body
                      .copyWith(color: AppColors.charcoal),
                ),
              ),
              const Icon(
                Icons.chevron_right,
                size: 20,
                color: AppColors.muted,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A non-tappable info row showing a label and value.
class _InfoTile extends StatelessWidget {
  const _InfoTile({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: AppColors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: <Widget>[
          Icon(icon, size: 22, color: AppColors.charcoal),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              label,
              style:
                  AppTypography.body.copyWith(color: AppColors.charcoal),
            ),
          ),
          Text(
            value,
            style: AppTypography.body.copyWith(color: AppColors.muted),
          ),
        ],
      ),
    );
  }
}
