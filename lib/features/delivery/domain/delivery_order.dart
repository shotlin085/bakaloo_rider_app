import 'package:flutter/foundation.dart';

import '../data/order_parser.dart';
import 'assignment_status.dart';
import 'delivery_address.dart';
import 'delivery_item.dart';
import 'order_parse_exception.dart';

/// A delivery assignment as returned by `/delivery/orders` and related
/// endpoints.
///
/// The parser is deliberately lenient (R19): it accepts both
/// snake_case and camelCase field names (R19.1), prefers camelCase
/// when both are present (R19.2), and converts numeric strings to
/// doubles for money / coordinate fields (R28.4).
///
/// Required fields (`orderId`, `assignmentStatus`) throw
/// [OrderParseException] when missing (R19.4). Unknown
/// `assignmentStatus` values throw [UnknownAssignmentStatusException]
/// (R19.5). Out-of-range coordinates anywhere inside the customer or
/// store address throw [InvalidCoordinateException] (R28.3).
@immutable
class DeliveryOrder {
  /// Constructs a delivery order explicitly.
  const DeliveryOrder({
    required this.orderId,
    this.assignmentId,
    required this.orderNumber,
    required this.assignmentStatus,
    this.orderStatus,
    required this.totalAmount,
    required this.paymentMethod,
    required this.riderEarning,
    this.estimatedDistance,
    required this.estimatedDuration,
    required this.customerAddress,
    required this.storeAddress,
    required this.items,
  });

  /// Lenient parser.
  ///
  /// Accepts both snake_case and camelCase field names. Throws
  /// [OrderParseException] for missing required fields,
  /// [UnknownAssignmentStatusException] for unknown statuses, and
  /// [InvalidCoordinateException] for out-of-range coordinates inside
  /// either nested address.
  factory DeliveryOrder.fromJson(Map<String, dynamic> j) {
    // Required: orderId
    final String? rawOrderId = OrderParser.readStringOpt(
      j,
      'orderId',
      'order_id',
    );
    if (rawOrderId == null || rawOrderId.isEmpty) {
      throw const OrderParseException('orderId');
    }

    // Required: assignmentStatus
    final String? rawStatus = OrderParser.readStringOpt(
      j,
      'assignmentStatus',
      'assignment_status',
    );
    if (rawStatus == null || rawStatus.isEmpty) {
      throw const OrderParseException('assignmentStatus');
    }
    final AssignmentStatus assignmentStatus =
        AssignmentStatus.parse(rawStatus);

    // Required: customerAddress and storeAddress (object shape).
    final Map<String, dynamic>? rawCustomer = OrderParser.readMap(
      j,
      'customerAddress',
      'customer_address',
    );
    if (rawCustomer == null) {
      throw const OrderParseException('customerAddress');
    }
    final Map<String, dynamic>? rawStore = OrderParser.readMap(
      j,
      'storeAddress',
      'store_address',
    );
    if (rawStore == null) {
      throw const OrderParseException('storeAddress');
    }

    return DeliveryOrder(
      orderId: rawOrderId,
      assignmentId:
          OrderParser.readStringOpt(j, 'assignmentId', 'assignment_id'),
      orderNumber: OrderParser.readStringOpt(j, 'orderNumber', 'order_number')
              ?.takeUnlessEmpty() ??
          rawOrderId,
      assignmentStatus: assignmentStatus,
      orderStatus: OrderParser.readStringOpt(j, 'orderStatus', 'order_status'),
      totalAmount: OrderParser.readMoney(j, 'totalAmount', 'total_amount'),
      paymentMethod:
          OrderParser.readString(j, 'paymentMethod', 'payment_method'),
      riderEarning: OrderParser.readMoney(j, 'riderEarning', 'rider_earning'),
      estimatedDistance: OrderParser.readDoubleOpt(
        j,
        'estimatedDistance',
        'estimated_distance',
      ),
      estimatedDuration:
          OrderParser.readInt(j, 'estimatedDuration', 'estimated_duration'),
      customerAddress: DeliveryAddress.fromJson(rawCustomer),
      storeAddress: DeliveryAddress.fromJson(rawStore),
      items: OrderParser.readMapList(j, 'items')
          .map<DeliveryItem>(DeliveryItem.fromJson)
          .toList(growable: false),
    );
  }

  /// Serialises to camelCase JSON (R19.3 round-trip).
  Map<String, dynamic> toJson() => <String, dynamic>{
        'orderId': orderId,
        if (assignmentId != null) 'assignmentId': assignmentId,
        'orderNumber': orderNumber,
        'assignmentStatus': assignmentStatus.wire,
        if (orderStatus != null) 'orderStatus': orderStatus,
        'totalAmount': totalAmount,
        'paymentMethod': paymentMethod,
        'riderEarning': riderEarning,
        if (estimatedDistance != null) 'estimatedDistance': estimatedDistance,
        'estimatedDuration': estimatedDuration,
        'customerAddress': customerAddress.toJson(),
        'storeAddress': storeAddress.toJson(),
        'items': items.map((DeliveryItem i) => i.toJson()).toList(),
      };

  /// Returns a copy with the supplied fields replaced.
  DeliveryOrder copyWith({
    String? orderId,
    String? assignmentId,
    String? orderNumber,
    AssignmentStatus? assignmentStatus,
    String? orderStatus,
    double? totalAmount,
    String? paymentMethod,
    double? riderEarning,
    double? estimatedDistance,
    int? estimatedDuration,
    DeliveryAddress? customerAddress,
    DeliveryAddress? storeAddress,
    List<DeliveryItem>? items,
  }) {
    return DeliveryOrder(
      orderId: orderId ?? this.orderId,
      assignmentId: assignmentId ?? this.assignmentId,
      orderNumber: orderNumber ?? this.orderNumber,
      assignmentStatus: assignmentStatus ?? this.assignmentStatus,
      orderStatus: orderStatus ?? this.orderStatus,
      totalAmount: totalAmount ?? this.totalAmount,
      paymentMethod: paymentMethod ?? this.paymentMethod,
      riderEarning: riderEarning ?? this.riderEarning,
      estimatedDistance: estimatedDistance ?? this.estimatedDistance,
      estimatedDuration: estimatedDuration ?? this.estimatedDuration,
      customerAddress: customerAddress ?? this.customerAddress,
      storeAddress: storeAddress ?? this.storeAddress,
      items: items ?? this.items,
    );
  }

  /// Order identifier (UUID).
  final String orderId;

  /// Assignment identifier. May be null for orders returned without an
  /// explicit assignment record.
  final String? assignmentId;

  /// Human-readable order number (e.g. `ORD-1234`).
  final String orderNumber;

  /// Current assignment lifecycle state.
  final AssignmentStatus assignmentStatus;

  /// Order status string from the backend (e.g. `CONFIRMED`, `PACKED`).
  final String? orderStatus;

  /// Total order amount, rounded to 2 decimal places.
  final double totalAmount;

  /// Payment method (e.g. `ONLINE`, `COD`).
  final String paymentMethod;

  /// Rider's earning for this delivery, rounded to 2 decimal places.
  final double riderEarning;

  /// Estimated delivery distance in kilometres. Null when not provided.
  final double? estimatedDistance;

  /// Estimated delivery duration in minutes.
  final int estimatedDuration;

  /// Customer delivery address.
  final DeliveryAddress customerAddress;

  /// Store pickup address.
  final DeliveryAddress storeAddress;

  /// Line items in the order.
  final List<DeliveryItem> items;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! DeliveryOrder) return false;
    if (other.orderId != orderId) return false;
    if (other.assignmentId != assignmentId) return false;
    if (other.orderNumber != orderNumber) return false;
    if (other.assignmentStatus != assignmentStatus) return false;
    if (other.orderStatus != orderStatus) return false;
    if (other.totalAmount != totalAmount) return false;
    if (other.paymentMethod != paymentMethod) return false;
    if (other.riderEarning != riderEarning) return false;
    if (other.estimatedDistance != estimatedDistance) return false;
    if (other.estimatedDuration != estimatedDuration) return false;
    if (other.customerAddress != customerAddress) return false;
    if (other.storeAddress != storeAddress) return false;
    if (other.items.length != items.length) return false;
    for (int i = 0; i < items.length; i++) {
      if (other.items[i] != items[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(
        orderId,
        assignmentId,
        orderNumber,
        assignmentStatus,
        orderStatus,
        totalAmount,
        paymentMethod,
        riderEarning,
        estimatedDistance,
        estimatedDuration,
        customerAddress,
        storeAddress,
        Object.hashAll(items),
      );

  @override
  String toString() =>
      'DeliveryOrder(orderId=$orderId, status=${assignmentStatus.wire}, '
      'earning=$riderEarning)';
}

extension on String {
  /// Returns this string when non-empty, else null. Used to distinguish
  /// "missing or empty" from "present with content" without re-running
  /// the parser.
  String? takeUnlessEmpty() => isEmpty ? null : this;
}
