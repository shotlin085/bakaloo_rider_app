import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/providers.dart';
import '../../../app/router.dart';
import '../../../core/config/app_constants.dart';
import '../../../core/config/env.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_typography.dart';
import '../../../shared/widgets/app_button.dart';
import '../application/auth_controller.dart';
import '../application/auth_state.dart';

/// OTP entry screen.
///
/// Renders a single 6-digit input bound to a single `TextField`
/// (rather than per-digit boxes) to keep accessibility, paste support,
/// and platform autofill working out of the box. The premium minimal
/// look comes from the input style and the full-width black CTA.
class OtpScreen extends ConsumerStatefulWidget {
  /// Const constructor so the route can use `const OtpScreen()`.
  const OtpScreen({super.key});

  @override
  ConsumerState<OtpScreen> createState() => _OtpScreenState();
}

class _OtpScreenState extends ConsumerState<OtpScreen> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focus = FocusNode();
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    // Auto-fill the dev OTP whenever the controller surfaces one in dev
    // builds, and refresh the resend countdown every second.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focus.requestFocus();
      _maybePrefillDevOtp();
    });
    _ticker = Timer.periodic(
      const Duration(seconds: 1),
      (_) {
        if (mounted) setState(() {});
      },
    );
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _maybePrefillDevOtp() {
    final Env env = ref.read<Env>(envProvider);
    if (!env.enableDevAffordances) return;
    final String? otp =
        ref.read<AuthController>(authControllerProvider).state.devOtp;
    if (otp != null && otp.length == AppConstants.loginOtpLength &&
        _controller.text.isEmpty) {
      _controller.text = otp;
    }
  }

  Future<void> _onVerify() async {
    FocusScope.of(context).unfocus();
    final String value = _controller.text.trim();
    if (value.length != AppConstants.loginOtpLength) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter the 6-digit OTP')),
      );
      return;
    }
    final AuthController auth =
        ref.read<AuthController>(authControllerProvider);
    final result = await auth.verifyOtp(value);
    if (!mounted) return;
    if (result != null) {
      // Router redirect handles destination; just leave the OTP screen.
      context.go(AppRoutes.splash);
    }
  }

  Future<void> _onResend() async {
    final AuthController auth =
        ref.read<AuthController>(authControllerProvider);
    if (!auth.canResend()) return;
    await auth.resendOtp();
  }

  @override
  Widget build(BuildContext context) {
    final AuthController auth =
        ref.watch<AuthController>(authControllerProvider);
    final AuthState state = auth.state;
    final Env env = ref.watch<Env>(envProvider);

    final int remaining = auth.resendSecondsRemaining();
    final bool canResend = auth.canResend();
    final bool busy = state.isBusy;

    return Scaffold(
      backgroundColor: AppColors.white,
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () {
            auth.reset();
            context.go(AppRoutes.login);
          },
        ),
        title: const Text('Verify number'),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              const SizedBox(height: 8),
              Text(
                state.phone == null
                    ? 'Enter the OTP we just sent'
                    : 'Enter the OTP sent to ${state.phone}',
                style:
                    AppTypography.body.copyWith(color: AppColors.muted),
              ),
              const SizedBox(height: 24),
              _OtpInputField(
                controller: _controller,
                focus: _focus,
                onSubmitted: (_) => _onVerify(),
                errorText: state.errorMessage,
              ),
              const SizedBox(height: 16),
              if (env.enableDevAffordances && state.devOtp != null)
                _DevOtpHint(otp: state.devOtp!),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  Text(
                    canResend
                        ? "Didn't get the OTP?"
                        : 'Resend OTP in ${remaining}s',
                    style: AppTypography.label
                        .copyWith(color: AppColors.muted),
                  ),
                  const SizedBox(width: 4),
                  if (canResend)
                    TextButton(
                      onPressed: busy ? null : _onResend,
                      child: const Text('Resend'),
                    ),
                ],
              ),
              const Spacer(),
              AppButton(
                label: 'Verify',
                isLoading: state.phase == AuthPhase.verifyingOtp,
                onPressed: busy ? null : _onVerify,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Visual treatment for the OTP input: large monospace digits on the
/// off-white surface, centered, with a charcoal underline-on-focus.
class _OtpInputField extends StatelessWidget {
  const _OtpInputField({
    required this.controller,
    required this.focus,
    required this.onSubmitted,
    this.errorText,
  });

  final TextEditingController controller;
  final FocusNode focus;
  final ValueChanged<String> onSubmitted;
  final String? errorText;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Container(
          decoration: BoxDecoration(
            color: AppColors.offWhite,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: errorText != null ? AppColors.danger : AppColors.border,
              width: 1,
            ),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: TextField(
            controller: controller,
            focusNode: focus,
            autofocus: true,
            keyboardType: TextInputType.number,
            textAlign: TextAlign.center,
            maxLength: AppConstants.loginOtpLength,
            inputFormatters: <TextInputFormatter>[
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(AppConstants.loginOtpLength),
            ],
            style: AppTypography.title.copyWith(
              letterSpacing: 8,
              color: AppColors.charcoal,
            ),
            cursorColor: AppColors.charcoal,
            decoration: const InputDecoration(
              border: InputBorder.none,
              counterText: '',
              hintText: '······',
            ),
            onSubmitted: onSubmitted,
          ),
        ),
        if (errorText != null) ...<Widget>[
          const SizedBox(height: 6),
          Text(
            errorText!,
            style: AppTypography.micro.copyWith(color: AppColors.danger),
            textAlign: TextAlign.center,
          ),
        ],
      ],
    );
  }
}

class _DevOtpHint extends StatelessWidget {
  const _DevOtpHint({required this.otp});

  final String otp;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.offWhite,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: <Widget>[
          const Icon(Icons.lock_clock, size: 16, color: AppColors.muted),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Dev OTP: $otp',
              style: AppTypography.label
                  .copyWith(color: AppColors.charcoal, letterSpacing: 1),
            ),
          ),
        ],
      ),
    );
  }
}
