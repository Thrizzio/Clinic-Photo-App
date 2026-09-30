import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import '../models/patient.dart';
import '../services/database.dart';

class NewPatientDialog extends StatefulWidget {
  final AppDatabase database;

  const NewPatientDialog({
    super.key,
    required this.database,
  });

  /// Displays the dialog and returns the created or selected existing [Patient], or null if cancelled.
  static Future<Patient?> show(
    BuildContext context, {
    required AppDatabase database,
  }) {
    return showDialog<Patient>(
      context: context,
      barrierDismissible: false,
      builder: (_) => NewPatientDialog(database: database),
    );
  }

  @override
  State<NewPatientDialog> createState() => _NewPatientDialogState();
}

class _NewPatientDialogState extends State<NewPatientDialog> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _phoneController = TextEditingController();
  bool _isChecking = false;
  String? _errorMessage;

  @override
  void dispose() {
    _nameController.dispose();
    _phoneController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    final rawName = _nameController.text.trim();
    final rawPhone = _phoneController.text.trim();
    final normName = Patient.normalizeName(rawName);
    final normPhone = Patient.normalizePhone(rawPhone);

    if (normPhone == null) {
      setState(() {
        _errorMessage = 'Please enter a valid 10-digit Indian phone number.';
      });
      return;
    }

    setState(() {
      _isChecking = true;
      _errorMessage = null;
    });

    try {
      // Real-time deduplication check against local SQLite
      final existing = await widget.database.getPatientByBusinessIdentity(normName, normPhone);
      if (!mounted) return;

      if (existing != null) {
        setState(() {
          _isChecking = false;
        });

        final shouldOpen = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Patient Already Exists'),
            content: Text(
              'A patient with this name and phone number already exists:\n\n'
              '${existing.displayName}\n'
              'Phone: ${existing.phoneDisplay ?? normPhone}\n\n'
              'Would you like to open this existing patient instead?',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('Open Patient'),
              ),
            ],
          ),
        );

        if (shouldOpen == true && mounted) {
          Navigator.of(context).pop(existing);
        }
        return;
      }

      // No duplicate -> create new doctor-created patient with local UUID
      final now = DateTime.now();
      final newPatient = Patient(
        id: const Uuid().v4(),
        name: rawName,
        displayName: rawName,
        normalizedName: normName,
        phoneNumber: rawPhone,
        phoneDisplay: rawPhone,
        normalizedPhone: normPhone,
        source: PatientSource.doctorCreated,
        folderStatus: FolderStatus.missing,
        createdAt: now,
        updatedAt: now,
      );

      await widget.database.upsertPatients([newPatient]);

      if (mounted) {
        Navigator.of(context).pop(newPatient);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = 'Failed to create patient: $e';
          _isChecking = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      title: const Text('New Patient'),
      content: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Enter patient details to begin capturing photos.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _nameController,
                autofocus: true,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(
                  labelText: 'Patient Name *',
                  hintText: 'e.g. Abhijit Gaikwad',
                  prefixIcon: Icon(Icons.person_outline),
                  border: OutlineInputBorder(),
                ),
                validator: (value) {
                  if (value == null || value.trim().isEmpty) {
                    return 'Patient name is required';
                  }
                  if (value.trim().length < 2) {
                    return 'Name is too short';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 14),
              TextFormField(
                controller: _phoneController,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(
                  labelText: 'Phone Number *',
                  hintText: 'e.g. 9373264424',
                  prefixIcon: Icon(Icons.phone_outlined),
                  border: OutlineInputBorder(),
                ),
                validator: (value) {
                  if (value == null || value.trim().isEmpty) {
                    return 'Phone number is required';
                  }
                  final norm = Patient.normalizePhone(value.trim());
                  if (norm == null || norm.length != 10) {
                    return 'Enter a valid 10-digit Indian phone number';
                  }
                  return null;
                },
              ),
              if (_errorMessage != null) ...[
                const SizedBox(height: 12),
                Text(
                  _errorMessage!,
                  style: TextStyle(color: theme.colorScheme.error, fontSize: 13),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isChecking ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          onPressed: _isChecking ? null : _submit,
          icon: _isChecking
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                )
              : const Icon(Icons.check),
          label: const Text('Create Patient'),
        ),
      ],
    );
  }
}
