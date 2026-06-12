import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../../core/providers.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_typography.dart';
import '../../../shared/widgets/app_button.dart';
import '../application/documents_controller.dart';
import '../domain/rider_document.dart';

/// Screen for uploading a single rider verification document.
///
/// Receives the document [type] as a constructor parameter. Shows a
/// camera/gallery picker, a linear upload progress indicator while the
/// upload is in flight, and an error state with a retry button on failure.
///
/// On success, pops back to the approval screen and triggers a documents
/// refresh via [DocumentsController].
class DocumentUploadScreen extends ConsumerStatefulWidget {
  /// Creates a [DocumentUploadScreen] for the given document [type].
  const DocumentUploadScreen({super.key, required this.type});

  /// The document type to upload.
  final RiderDocumentType type;

  @override
  ConsumerState<DocumentUploadScreen> createState() =>
      _DocumentUploadScreenState();
}

class _DocumentUploadScreenState extends ConsumerState<DocumentUploadScreen> {
  final ImagePicker _picker = ImagePicker();

  File? _selectedFile;
  bool _uploading = false;

  String get _displayName => widget.type.displayName;

  Future<void> _pickImage(ImageSource source) async {
    try {
      final XFile? picked = await _picker.pickImage(
        source: source,
        imageQuality: 100, // compression handled by ImageCompressor
        maxWidth: 4096,
        maxHeight: 4096,
      );
      if (picked == null) return;
      setState(() {
        _selectedFile = File(picked.path);
      });
    } catch (_) {
      // User cancelled or permission denied — do nothing.
    }
  }

  Future<void> _upload() async {
    final File? file = _selectedFile;
    if (file == null) return;

    setState(() => _uploading = true);

    final DocumentsController controller =
        ref.read<DocumentsController>(documentsControllerProvider);
    await controller.upload(widget.type, file);

    if (!mounted) return;
    setState(() => _uploading = false);

    final bool failed = controller.uploadErrors.containsKey(widget.type);
    if (!failed) {
      // Invalidate the cached rider profile so `is_approved` refreshes.
      ref.invalidate(riderProfileProvider);
      // Brief pause so the user sees the progress complete before pop.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      if (mounted) Navigator.of(context).pop(true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final DocumentsController controller =
        ref.watch<DocumentsController>(documentsControllerProvider);
    final double? progress = controller.uploadProgress[widget.type];
    final String? errorMessage = controller.uploadErrors[widget.type];
    final bool showProgress = _uploading || progress != null;

    return Scaffold(
      backgroundColor: AppColors.white,
      appBar: AppBar(
        backgroundColor: AppColors.white,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: AppColors.charcoal),
          onPressed: () => Navigator.of(context).pop(false),
        ),
        title: Text(
          _displayName,
          style: AppTypography.heading.copyWith(color: AppColors.charcoal),
        ),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              // Preview area
              Expanded(
                child: _selectedFile != null
                    ? _ImagePreview(file: _selectedFile!)
                    : _EmptyPreview(displayName: _displayName),
              ),
              const SizedBox(height: 24),

              // Upload progress
              if (showProgress) ...<Widget>[
                Text(
                  'Uploading…',
                  style: AppTypography.label.copyWith(color: AppColors.muted),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                LinearProgressIndicator(
                  value: progress,
                  backgroundColor: AppColors.border,
                  valueColor: const AlwaysStoppedAnimation<Color>(
                    AppColors.black,
                  ),
                  minHeight: 4,
                  borderRadius: BorderRadius.circular(2),
                ),
                const SizedBox(height: 16),
              ],

              // Error state
              if (errorMessage != null && !_uploading) ...<Widget>[
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
                          'Upload failed. Tap to retry',
                          style: AppTypography.label
                              .copyWith(color: AppColors.danger),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
              ],

              // Source picker buttons
              if (!_uploading) ...<Widget>[
                Row(
                  children: <Widget>[
                    Expanded(
                      child: AppButton(
                        label: 'Camera',
                        variant: AppButtonVariant.secondary,
                        leadingIcon: Icons.camera_alt_outlined,
                        onPressed: () => _pickImage(ImageSource.camera),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: AppButton(
                        label: 'Gallery',
                        variant: AppButtonVariant.secondary,
                        leadingIcon: Icons.photo_library_outlined,
                        onPressed: () => _pickImage(ImageSource.gallery),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                AppButton(
                  label: errorMessage != null ? 'Retry upload' : 'Upload',
                  onPressed: _selectedFile != null ? _upload : null,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Shows the selected image as a preview.
class _ImagePreview extends StatelessWidget {
  const _ImagePreview({required this.file});
  final File file;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: Image.file(
        file,
        fit: BoxFit.contain,
        width: double.infinity,
      ),
    );
  }
}

/// Placeholder shown before an image is selected.
class _EmptyPreview extends StatelessWidget {
  const _EmptyPreview({required this.displayName});
  final String displayName;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.offWhite,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          const Icon(
            Icons.upload_file_outlined,
            size: 48,
            color: AppColors.muted,
          ),
          const SizedBox(height: 12),
          Text(
            'Select a photo of your\n$displayName',
            style: AppTypography.body.copyWith(color: AppColors.muted),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            'Use camera or gallery below',
            style: AppTypography.label.copyWith(color: AppColors.muted),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}
