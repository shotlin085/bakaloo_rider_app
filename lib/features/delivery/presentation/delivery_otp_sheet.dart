import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/app_constants.dart';
import '../../../core/providers.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/utils/action_failure_watcher.dart';
import '../../../core/utils/image_compressor.dart';
import '../../../shared/widgets/app_bottom_sheet.dart';
import '../../../shared/widgets/app_button.dart';
import '../../../shared/widgets/app_text_field.dart';
import '../../../shared/widgets/diagnostic_expander.dart';
import '../application/active_delivery_controller.dart';
import '../domain/delivery_order.dart';
import '../domain/delivery_outcome.dart';
import 'proof_upload_sheet.dart';

/// Presents the OTP-entry bottom sheet for [order] (R14).
///
/// Sheet contents:
/// - Title: "Verify delivery".
/// - 4-digit OTP input (digit-only, big monospace digits, autofocus,
///   paste-friendly).
/// - "Verify & deliver" primary button.
/// - Inline error row: surfaces invalid-OTP and other inline failures.
/// - Footer "Use proof photo instead" tertiary button — always visible
///   (R14.6 / R15).
///
/// Behaviour:
/// - On submit success (controller returns `DeliveryResultSuccess`)
///   the sheet dismisses with [DeliveryOutcomeDelivered].
/// - On `INVALID_OTP` the sheet stays open and renders the inline
///   error "OTP did not match. Ask the customer to read it again"
///   (R14.5).
/// - On `OTP_EXPIRED` the sheet switches to the proof flow **inline**
///   (R14.6); the deliver flow is NOT dismissed. The proof UI then
///   drives the rest of the lifecycle through the same controller.
/// - On `ORDER_NOT_AVAILABLE` / generic failure the sheet dismisses
///   with [DeliveryOutcomeFailed] so the caller can surface the
///   message.
/// - The footer "Use proof photo instead" button switches to the
///   inline proof flow immediately.
Future<DeliveryOutcome> showDeliveryOtpSheet(
  BuildContext context,
  DeliveryOrder order, {
  ProofImagePicker imagePicker = defaultProofImagePicker,
}) async {
  final DeliveryOutcome? result = await showAppBottomSheet<DeliveryOutcome>(
    context,
    initialChildSize: 0.82,
    builder: (BuildContext sheetContext) => _DeliveryOtpSheetBody(
      order: order,
      imagePicker: imagePicker,
    ),
  );
  return result ?? const DeliveryOutcomeCancelled();
}

class _DeliveryOtpSheetBody extends ConsumerStatefulWidget {
  const _DeliveryOtpSheetBody({
    required this.order,
    required this.imagePicker,
  });

  final DeliveryOrder order;
  final ProofImagePicker imagePicker;

  @override
  ConsumerState<_DeliveryOtpSheetBody> createState() =>
      _DeliveryOtpSheetBodyState();
}

/// Two phases the body cycles through:
/// - [otp]: the rider enters the customer's OTP (default).
/// - [proof]: same sheet, swapped to the proof-photo flow after either
///   the rider tapping "Use proof photo instead" or the backend
///   returning `OTP_EXPIRED`.
enum _Phase { otp, proof }

class _DeliveryOtpSheetBodyState
    extends ConsumerState<_DeliveryOtpSheetBody> {
  final TextEditingController _otpController = TextEditingController();
  final FocusNode _otpFocus = FocusNode();
  String? _inlineError;
  _Phase _phase = _Phase.otp;
  String? _proofExpiredBanner;
  File? _proofPreview;
  bool _proofRetry = false;

  /// Tracks consecutive deliver failures for R27.5.
  final ActionFailureWatcher _failureWatcher = ActionFailureWatcher();

  /// Whether to render the diagnostic expander below the CTA.
  bool _showDiagnostic = false;

  /// Rows shown inside the diagnostic expander.
  List<MapEntry<String, String>> _diagnosticRows =
      const <MapEntry<String, String>>[];

  @override
  void dispose() {
    _otpController.dispose();
    _otpFocus.dispose();
    super.dispose();
  }

  bool get _otpComplete =>
      _otpController.text.length == AppConstants.deliveryOtpLength;

  Future<void> _onSubmitOtp() async {
    final ActiveDeliveryController controller =
        ref.read<ActiveDeliveryController>(activeDeliveryControllerProvider);
    final NavigatorState navigator = Navigator.of(context);

    final DeliveryResult result = await controller.deliverWithOtp(
      widget.order.orderId,
      _otpController.text,
    );

    if (!navigator.mounted) return;
    switch (result) {
      case DeliveryResultSuccess(orderEarning: final double earned):
        // Reset failure counter on success.
        _failureWatcher.reset(widget.order.orderId);
        navigator.pop<DeliveryOutcome>(
          DeliveryOutcomeDelivered(
            orderId: widget.order.orderId,
            earnedAmount: earned,
            totalToday: earned,
          ),
        );
      case DeliveryResultStale(message: final String message):
      case DeliveryResultFailure(message: final String message):
        _failureWatcher.record(widget.order.orderId, message);
        final bool showDiag = _failureWatcher.shouldShowDiagnostic(
          widget.order.orderId,
        );
        setState(() {
          _showDiagnostic = showDiag;
          _diagnosticRows = _failureWatcher.diagnosticRows(
            widget.order.orderId,
          );
        });
        navigator.pop<DeliveryOutcome>(DeliveryOutcomeFailed(message));
      case DeliveryResultInvalidOtp(message: final String message):
        // R14.5: keep the sheet open with an inline error.
        _failureWatcher.record(widget.order.orderId, message);
        final bool showDiag = _failureWatcher.shouldShowDiagnostic(
          widget.order.orderId,
        );
        setState(() {
          _inlineError = message;
          _showDiagnostic = showDiag;
          _diagnosticRows = _failureWatcher.diagnosticRows(
            widget.order.orderId,
          );
        });
      case DeliveryResultOtpExpired(message: final String message):
        // R14.6: switch to the proof flow inline; do NOT dismiss.
        setState(() {
          _phase = _Phase.proof;
          _inlineError = null;
          _showDiagnostic = false;
          _proofExpiredBanner =
              message.isNotEmpty ? message : 'OTP expired. Use proof photo';
        });
      case DeliveryResultProofFailed(message: final String message):
        setState(() => _inlineError = message);
    }
  }

  void _onUseProofInstead() {
    setState(() {
      _phase = _Phase.proof;
      _inlineError = null;
      _proofExpiredBanner = null;
    });
  }

  Future<void> _onPickProof() async {
    final File? captured = await widget.imagePicker();
    if (!mounted || captured == null) return;
    setState(() {
      _proofPreview = captured;
      _proofRetry = false;
    });
  }

  Future<void> _onUploadProof() async {
    final File? source = _proofPreview;
    if (source == null) return;

    final ActiveDeliveryController controller =
        ref.read<ActiveDeliveryController>(activeDeliveryControllerProvider);
    final ImageCompressor compressor =
        ref.read<ImageCompressor>(imageCompressorProvider);
    final NavigatorState navigator = Navigator.of(context);

    File compressed;
    try {
      compressed = await compressor.compress(source);
    } catch (_) {
      compressed = source;
    }

    final DeliveryResult result = await controller.deliverWithProof(
      widget.order.orderId,
      compressed,
    );

    if (!navigator.mounted) return;
    switch (result) {
      case DeliveryResultSuccess(orderEarning: final double earned):
        // Reset failure counter on success.
        _failureWatcher.reset(widget.order.orderId);
        navigator.pop<DeliveryOutcome>(
          DeliveryOutcomeDelivered(
            orderId: widget.order.orderId,
            earnedAmount: earned,
            totalToday: earned,
          ),
        );
      case DeliveryResultStale(message: final String message):
      case DeliveryResultFailure(message: final String message):
        _failureWatcher.record(widget.order.orderId, message);
        final bool showDiag = _failureWatcher.shouldShowDiagnostic(
          widget.order.orderId,
        );
        setState(() {
          _showDiagnostic = showDiag;
          _diagnosticRows = _failureWatcher.diagnosticRows(
            widget.order.orderId,
          );
        });
        navigator.pop<DeliveryOutcome>(DeliveryOutcomeFailed(message));
      case DeliveryResultProofFailed():
        // R15.4: keep the sheet open, show retry.
        setState(() => _proofRetry = true);
      case DeliveryResultInvalidOtp(message: final String message):
      case DeliveryResultOtpExpired(message: final String message):
        setState(() => _inlineError = message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ActiveDeliveryController controller =
        ref.watch<ActiveDeliveryController>(activeDeliveryControllerProvider);
    final bool busy = controller.isBusy;

    return AppSheetScaffold(
      title: _phase == _Phase.otp ? 'Verify delivery' : 'Proof photo',
      child: _phase == _Phase.otp
          ? _buildOtpPhase(busy)
          : _buildProofPhase(busy),
    );
  }

  Widget _buildOtpPhase(bool busy) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          'Ask the customer for the 4-digit OTP shown in their app.',
          style: AppTypography.body.copyWith(color: AppColors.muted),
        ),
        const SizedBox(height: 16),
        AppTextField(
          controller: _otpController,
          label: 'Customer OTP',
          hint: '••••',
          keyboardType: TextInputType.number,
          inputFormatters: <TextInputFormatter>[
            FilteringTextInputFormatter.digitsOnly,
            LengthLimitingTextInputFormatter(
              AppConstants.deliveryOtpLength,
            ),
          ],
          autofocus: true,
          maxLength: AppConstants.deliveryOtpLength,
          onChanged: (_) {
            if (_inlineError != null) {
              setState(() => _inlineError = null);
            }
          },
          onSubmitted: (_) {
            if (_otpComplete && !busy) {
              unawaited(_onSubmitOtp());
            }
          },
          errorText: _inlineError,
          enabled: !busy,
        ),
        const SizedBox(height: 16),
        AppButton(
          label: 'Verify & deliver',
          isLoading: busy,
          onPressed: _otpComplete && !busy ? _onSubmitOtp : null,
        ),
        const SizedBox(height: 8),
        // Tertiary text button — always visible per R14.6 / R15.
        TextButton(
          onPressed: busy ? null : _onUseProofInstead,
          child: Text(
            'Use proof photo instead',
            style: AppTypography.label.copyWith(color: AppColors.charcoal),
          ),
        ),
        // R27.5: show diagnostic expander after 2+ failures within 10s.
        if (_showDiagnostic) ...<Widget>[
          const SizedBox(height: 12),
          DiagnosticExpander(
            summary: 'Show error details',
            rows: _diagnosticRows,
          ),
        ],
      ],
    );
  }

  Widget _buildProofPhase(bool busy) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (_proofExpiredBanner != null) ...<Widget>[
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.warning.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: AppColors.warning.withValues(alpha: 0.30),
              ),
            ),
            child: Row(
              children: <Widget>[
                const Icon(
                  Icons.info_outline,
                  size: 18,
                  color: AppColors.warning,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _proofExpiredBanner!,
                    style: AppTypography.label
                        .copyWith(color: AppColors.charcoal),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
        ],
        Text(
          'Take a photo of the delivery to confirm completion.',
          style: AppTypography.body.copyWith(color: AppColors.muted),
        ),
        const SizedBox(height: 12),
        AspectRatio(
          aspectRatio: 4 / 3,
          child: _proofPreview == null
              ? _EmptyPreview(onTap: busy ? null : _onPickProof)
              : _ImagePreview(file: _proofPreview!),
        ),
        const SizedBox(height: 12),
        if (_proofRetry) ...<Widget>[
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.danger.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: AppColors.danger.withValues(alpha: 0.3),
              ),
            ),
            child: Row(
              children: <Widget>[
                const Icon(
                  Icons.error_outline,
                  color: AppColors.danger,
                  size: 18,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Could not upload photo. Try again',
                    style: AppTypography.label
                        .copyWith(color: AppColors.danger),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
        ],
        if (_proofPreview != null) ...<Widget>[
          AppButton(
            label: _proofRetry ? 'Retry upload & deliver' : 'Upload & deliver',
            isLoading: busy,
            onPressed: busy ? null : _onUploadProof,
          ),
          const SizedBox(height: 8),
          AppButton(
            label: 'Retake photo',
            variant: AppButtonVariant.secondary,
            onPressed: busy ? null : _onPickProof,
          ),
        ] else ...<Widget>[
          AppButton(
            label: 'Open camera',
            leadingIcon: Icons.camera_alt_outlined,
            onPressed: busy ? null : _onPickProof,
          ),
        ],
      ],
    );
  }
}

class _EmptyPreview extends StatelessWidget {
  const _EmptyPreview({required this.onTap});

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: AppColors.offWhite,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.border),
        ),
        child: const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                Icons.photo_camera_outlined,
                size: 40,
                color: AppColors.muted,
              ),
              SizedBox(height: 8),
              Text(
                'Tap to capture proof',
                style: AppTypography.label,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ImagePreview extends StatelessWidget {
  const _ImagePreview({required this.file});

  final File file;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: Image.file(
        file,
        fit: BoxFit.cover,
        width: double.infinity,
      ),
    );
  }
}
