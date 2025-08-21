/// Core Result Type - Simplified and Optimized
/// ---------------------------------------------------------------------------
/// A lightweight functional result type for clean error handling without
/// exceptions. Provides ergonomic composition and transformation methods.
///
/// Example:
/// ```dart
/// Result<User> result = await userService.getUser('123');
/// result.when(
///   success: (user) => print('Hello ${user.name}'),
///   failure: (error) => print('Error: ${error.message}'),
/// );
/// ```
library core_result;

import 'dart:async';

/// Error types for classification
enum ErrorType {
  network,
  timeout,
  validation,
  unauthorized,
  forbidden,
  notFound,
  conflict,
  rateLimited,
  cancelled,
  serialization,
  unknown,
}

/// Lightweight error container
class AppError {
  final String message;
  final ErrorType type;
  final Object? cause;
  final int? statusCode;

  const AppError({
    required this.message,
    this.type = ErrorType.unknown,
    this.cause,
    this.statusCode,
  });

  @override
  String toString() => 'AppError($type: $message)';

  /// Smart error classification from exceptions
  factory AppError.fromException(Object error, {int? statusCode}) {
    final msg = error.toString();
    ErrorType type = ErrorType.unknown;

    if (msg.contains('SocketException') || msg.contains('Connection')) {
      type = ErrorType.network;
    } else if (msg.contains('TimeoutException')) {
      type = ErrorType.timeout;
    } else if (msg.contains('FormatException')) {
      type = ErrorType.serialization;
    } else if (statusCode == 401) {
      type = ErrorType.unauthorized;
    } else if (statusCode == 403) {
      type = ErrorType.forbidden;
    } else if (statusCode == 404) {
      type = ErrorType.notFound;
    } else if (statusCode == 409) {
      type = ErrorType.conflict;
    } else if (statusCode == 429) {
      type = ErrorType.rateLimited;
    } else if (msg.toLowerCase().contains('cancel')) {
      type = ErrorType.cancelled;
    }

    return AppError(
      message: msg,
      type: type,
      cause: error,
      statusCode: statusCode,
    );
  }
}

/// Sealed result type
sealed class Result<T> {
  const Result();

  /// Type checks
  bool get isSuccess => this is Success<T>;
  bool get isFailure => this is Failure<T>;

  /// Safe data access
  T? get data => isSuccess ? (this as Success<T>).value : null;
  AppError? get error => isFailure ? (this as Failure<T>).error : null;

  /// Pattern matching
  R when<R>({
    required R Function(T value) success,
    required R Function(AppError error) failure,
  }) => isSuccess
      ? success((this as Success<T>).value)
      : failure((this as Failure<T>).error);

  /// Transform success value
  Result<R> map<R>(R Function(T value) transform) => when(
    success: (value) => Success(transform(value)),
    failure: (error) => Failure<R>(error),
  );

  /// Chain results (flatMap)
  Result<R> flatMap<R>(Result<R> Function(T value) transform) =>
      when(success: transform, failure: (error) => Failure<R>(error));

  /// Handle errors
  Result<T> mapError(AppError Function(AppError error) transform) => when(
    success: (value) => Success(value),
    failure: (error) => Failure(transform(error)),
  );

  /// Side effects
  Result<T> onSuccess(void Function(T value) callback) {
    if (isSuccess) callback((this as Success<T>).value);
    return this;
  }

  Result<T> onFailure(void Function(AppError error) callback) {
    if (isFailure) callback((this as Failure<T>).error);
    return this;
  }

  /// Unwrap with fallback
  T getOrElse(T fallback) => data ?? fallback;
  T? getOrNull() => data;

  /// Async transformation
  Future<Result<R>> asyncMap<R>(FutureOr<R> Function(T value) transform) async {
    if (isFailure) return Failure<R>((this as Failure<T>).error);
    try {
      final result = await transform((this as Success<T>).value);
      return Success(result);
    } catch (e) {
      return Failure(AppError.fromException(e));
    }
  }

  @override
  String toString() => when(
    success: (value) => 'Success($value)',
    failure: (error) => 'Failure($error)',
  );
}

/// Success variant
class Success<T> extends Result<T> {
  final T value;
  const Success(this.value);
}

/// Failure variant
class Failure<T> extends Result<T> {
  @override
  final AppError error;
  const Failure(this.error);
}

/// Convenient typedefs
typedef AsyncResult<T> = Future<Result<T>>;

/// Utilities for safe execution
Result<T> catching<T>(T Function() fn) {
  try {
    return Success(fn());
  } catch (e) {
    return Failure(AppError.fromException(e));
  }
}

AsyncResult<T> catchingAsync<T>(Future<T> Function() fn) async {
  try {
    return Success(await fn());
  } catch (e) {
    return Failure(AppError.fromException(e));
  }
}

/// Combine multiple results
Result<List<T>> combineResults<T>(Iterable<Result<T>> results) {
  final values = <T>[];
  for (final result in results) {
    if (result.isFailure) return Failure(result.error!);
    values.add(result.data!);
  }
  return Success(values);
}
