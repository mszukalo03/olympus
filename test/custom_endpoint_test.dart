import 'package:flutter_test/flutter_test.dart';
import 'package:olympus/shared/services/custom/custom_endpoint_service.dart';

void main() {
  group('CustomEndpointService Tests', () {
    late CustomEndpointService service;

    setUp(() {
      service = CustomEndpointService.instance;
    });

    test('should parse messages correctly', () {
      final (shortcut1, query1) = service.parseMessage('/j The Matrix');
      expect(shortcut1, 'j');
      expect(query1, 'The Matrix');

      final (shortcut2, query2) = service.parseMessage('/search flutter tutorial');
      expect(shortcut2, 'search');
      expect(query2, 'flutter tutorial');

      final (shortcut3, query3) = service.parseMessage('/test');
      expect(shortcut3, 'test');
      expect(query3, '');
    });

    test('should throw on invalid message format', () {
      expect(() => service.parseMessage('no slash'), throwsArgumentError);
      expect(() => service.parseMessage(''), throwsArgumentError);
    });

    test('should validate endpoint configurations', () {
      // Valid configuration
      final validConfig = {
        'name': 'Test Service',
        'url': 'https://example.com/api',
        'type': 'jellyseerr', // Use a supported type
      };
      final validResult = service.validateEndpointConfig(validConfig);
      expect(validResult.isSuccess, true);

      // Invalid configuration - missing name
      final invalidConfig1 = {
        'url': 'https://example.com/api',
        'type': 'jellyseerr',
      };
      final invalidResult1 = service.validateEndpointConfig(invalidConfig1);
      expect(invalidResult1.isFailure, true);

      // Invalid configuration - bad URL
      final invalidConfig2 = {
        'name': 'Test',
        'url': 'not-a-url',
        'type': 'jellyseerr',
      };
      final invalidResult2 = service.validateEndpointConfig(invalidConfig2);
      expect(invalidResult2.isFailure, true);
    });
  });
}
