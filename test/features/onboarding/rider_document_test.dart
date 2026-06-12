import 'package:flutter_test/flutter_test.dart';

import 'package:grolin_rider_app/features/onboarding/domain/rider_document.dart';

void main() {
  group('RiderDocumentType.wire', () {
    test('returns the snake_case backend segment for every type', () {
      expect(RiderDocumentType.photo.wire, 'photo');
      expect(RiderDocumentType.drivingLicense.wire, 'driving_license');
      expect(RiderDocumentType.aadharFront.wire, 'aadhar_front');
      expect(RiderDocumentType.aadharBack.wire, 'aadhar_back');
      expect(RiderDocumentType.vehicleRc.wire, 'vehicle_rc');
      expect(RiderDocumentType.panCard.wire, 'pan_card');
    });

    test('every enum value has a unique wire string', () {
      final Set<String> wires = <String>{
        for (final RiderDocumentType t in RiderDocumentType.values) t.wire,
      };
      expect(wires.length, RiderDocumentType.values.length);
    });
  });

  group('RiderDocumentType.displayName', () {
    test('returns sentence-case copy used by the UI', () {
      expect(RiderDocumentType.photo.displayName, 'Profile photo');
      expect(RiderDocumentType.drivingLicense.displayName, 'Driving license');
      expect(RiderDocumentType.aadharFront.displayName, 'Aadhaar front');
      expect(RiderDocumentType.aadharBack.displayName, 'Aadhaar back');
      expect(RiderDocumentType.vehicleRc.displayName, 'Vehicle RC');
      expect(RiderDocumentType.panCard.displayName, 'PAN card');
    });
  });

  group('RiderDocumentType.fromWire round-trip', () {
    test('parse(t.wire) == t for every enum value', () {
      for (final RiderDocumentType t in RiderDocumentType.values) {
        expect(
          RiderDocumentType.fromWire(t.wire),
          t,
          reason: 'fromWire failed to round-trip ${t.wire}',
        );
      }
    });

    test('returns null for unknown wire strings', () {
      expect(RiderDocumentType.fromWire('unknown_doc'), isNull);
      expect(RiderDocumentType.fromWire(''), isNull);
      expect(RiderDocumentType.fromWire(null), isNull);
    });
  });

  group('RiderDocumentStatus.parse (live backend casing)', () {
    test('handles upper-case strings the live backend emits', () {
      expect(RiderDocumentStatus.parse('PENDING'), RiderDocumentStatus.pending);
      expect(
        RiderDocumentStatus.parse('APPROVED'),
        RiderDocumentStatus.approved,
      );
      expect(
        RiderDocumentStatus.parse('REJECTED'),
        RiderDocumentStatus.rejected,
      );
      expect(RiderDocumentStatus.parse('MISSING'), RiderDocumentStatus.missing);
    });

    test('is case-insensitive', () {
      expect(RiderDocumentStatus.parse('pending'), RiderDocumentStatus.pending);
      expect(
        RiderDocumentStatus.parse('Approved'),
        RiderDocumentStatus.approved,
      );
      expect(
        RiderDocumentStatus.parse('rejected'),
        RiderDocumentStatus.rejected,
      );
    });

    test('null, empty, and unknown all map to missing', () {
      expect(RiderDocumentStatus.parse(null), RiderDocumentStatus.missing);
      expect(RiderDocumentStatus.parse(''), RiderDocumentStatus.missing);
      expect(
        RiderDocumentStatus.parse('  '),
        RiderDocumentStatus.missing,
      );
      expect(
        RiderDocumentStatus.parse('SUBMITTED'),
        RiderDocumentStatus.missing,
      );
    });
  });

  group('RiderDocument.fromJson', () {
    test('parses a fully-populated camelCase payload', () {
      final RiderDocument doc = RiderDocument.fromJson(<String, dynamic>{
        'type': 'photo',
        'status': 'APPROVED',
        'url': 'https://example.com/photo.jpg',
        'uploadedAt': '2026-05-15T10:00:00Z',
      });
      expect(doc.type, RiderDocumentType.photo);
      expect(doc.status, RiderDocumentStatus.approved);
      expect(doc.url, 'https://example.com/photo.jpg');
      expect(doc.uploadedAt, DateTime.utc(2026, 5, 15, 10, 0, 0));
    });

    test('accepts snake_case alternates: document_type / document_url / '
        'uploaded_at', () {
      final RiderDocument doc = RiderDocument.fromJson(<String, dynamic>{
        'document_type': 'driving_license',
        'status': 'PENDING',
        'document_url': 'https://example.com/dl.jpg',
        'uploaded_at': '2026-05-15T10:00:00Z',
      });
      expect(doc.type, RiderDocumentType.drivingLicense);
      expect(doc.status, RiderDocumentStatus.pending);
      expect(doc.url, 'https://example.com/dl.jpg');
      expect(doc.uploadedAt, isNotNull);
    });

    test('defaults status to missing when absent', () {
      final RiderDocument doc = RiderDocument.fromJson(<String, dynamic>{
        'type': 'pan_card',
      });
      expect(doc.status, RiderDocumentStatus.missing);
      expect(doc.url, isNull);
    });

    test('throws FormatException for unknown type wire string', () {
      expect(
        () => RiderDocument.fromJson(<String, dynamic>{
          'type': 'unknown_doc',
          'status': 'PENDING',
        }),
        throwsA(isA<FormatException>()),
      );
    });

    test('captures rejection_reason in either casing', () {
      final RiderDocument camel = RiderDocument.fromJson(<String, dynamic>{
        'type': 'aadhar_front',
        'status': 'REJECTED',
        'rejectionReason': 'Blurry',
      });
      expect(camel.rejectionReason, 'Blurry');

      final RiderDocument snake = RiderDocument.fromJson(<String, dynamic>{
        'type': 'aadhar_back',
        'status': 'REJECTED',
        'rejection_reason': 'Wrong side',
      });
      expect(snake.rejectionReason, 'Wrong side');
    });
  });
}
