// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'app_database.dart';

// ignore_for_file: type=lint
class $SemestersTable extends Semesters
    with TableInfo<$SemestersTable, Semester> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SemestersTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
      'id', aliasedName, false,
      hasAutoIncrement: true,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('PRIMARY KEY AUTOINCREMENT'));
  static const VerificationMeta _uuidMeta = const VerificationMeta('uuid');
  @override
  late final GeneratedColumn<String> uuid = GeneratedColumn<String>(
      'uuid', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant(''));
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
      'name', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _startDateMeta =
      const VerificationMeta('startDate');
  @override
  late final GeneratedColumn<DateTime> startDate = GeneratedColumn<DateTime>(
      'start_date', aliasedName, false,
      type: DriftSqlType.dateTime, requiredDuringInsert: true);
  static const VerificationMeta _totalWeeksMeta =
      const VerificationMeta('totalWeeks');
  @override
  late final GeneratedColumn<int> totalWeeks = GeneratedColumn<int>(
      'total_weeks', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(20));
  static const VerificationMeta _isCurrentMeta =
      const VerificationMeta('isCurrent');
  @override
  late final GeneratedColumn<bool> isCurrent = GeneratedColumn<bool>(
      'is_current', aliasedName, false,
      type: DriftSqlType.bool,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('CHECK ("is_current" IN (0, 1))'),
      defaultValue: const Constant(false));
  static const VerificationMeta _updatedAtMeta =
      const VerificationMeta('updatedAt');
  @override
  late final GeneratedColumn<DateTime> updatedAt = GeneratedColumn<DateTime>(
      'updated_at', aliasedName, false,
      type: DriftSqlType.dateTime,
      requiredDuringInsert: false,
      defaultValue: currentDateAndTime);
  @override
  List<GeneratedColumn> get $columns =>
      [id, uuid, name, startDate, totalWeeks, isCurrent, updatedAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'semesters';
  @override
  VerificationContext validateIntegrity(Insertable<Semester> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('uuid')) {
      context.handle(
          _uuidMeta, uuid.isAcceptableOrUnknown(data['uuid']!, _uuidMeta));
    }
    if (data.containsKey('name')) {
      context.handle(
          _nameMeta, name.isAcceptableOrUnknown(data['name']!, _nameMeta));
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('start_date')) {
      context.handle(_startDateMeta,
          startDate.isAcceptableOrUnknown(data['start_date']!, _startDateMeta));
    } else if (isInserting) {
      context.missing(_startDateMeta);
    }
    if (data.containsKey('total_weeks')) {
      context.handle(
          _totalWeeksMeta,
          totalWeeks.isAcceptableOrUnknown(
              data['total_weeks']!, _totalWeeksMeta));
    }
    if (data.containsKey('is_current')) {
      context.handle(_isCurrentMeta,
          isCurrent.isAcceptableOrUnknown(data['is_current']!, _isCurrentMeta));
    }
    if (data.containsKey('updated_at')) {
      context.handle(_updatedAtMeta,
          updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  Semester map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return Semester(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}id'])!,
      uuid: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}uuid'])!,
      name: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}name'])!,
      startDate: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}start_date'])!,
      totalWeeks: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}total_weeks'])!,
      isCurrent: attachedDatabase.typeMapping
          .read(DriftSqlType.bool, data['${effectivePrefix}is_current'])!,
      updatedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}updated_at'])!,
    );
  }

  @override
  $SemestersTable createAlias(String alias) {
    return $SemestersTable(attachedDatabase, alias);
  }
}

class Semester extends DataClass implements Insertable<Semester> {
  final int id;
  final String uuid;
  final String name;
  final DateTime startDate;
  final int totalWeeks;
  final bool isCurrent;
  final DateTime updatedAt;
  const Semester(
      {required this.id,
      required this.uuid,
      required this.name,
      required this.startDate,
      required this.totalWeeks,
      required this.isCurrent,
      required this.updatedAt});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['uuid'] = Variable<String>(uuid);
    map['name'] = Variable<String>(name);
    map['start_date'] = Variable<DateTime>(startDate);
    map['total_weeks'] = Variable<int>(totalWeeks);
    map['is_current'] = Variable<bool>(isCurrent);
    map['updated_at'] = Variable<DateTime>(updatedAt);
    return map;
  }

  SemestersCompanion toCompanion(bool nullToAbsent) {
    return SemestersCompanion(
      id: Value(id),
      uuid: Value(uuid),
      name: Value(name),
      startDate: Value(startDate),
      totalWeeks: Value(totalWeeks),
      isCurrent: Value(isCurrent),
      updatedAt: Value(updatedAt),
    );
  }

  factory Semester.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return Semester(
      id: serializer.fromJson<int>(json['id']),
      uuid: serializer.fromJson<String>(json['uuid']),
      name: serializer.fromJson<String>(json['name']),
      startDate: serializer.fromJson<DateTime>(json['startDate']),
      totalWeeks: serializer.fromJson<int>(json['totalWeeks']),
      isCurrent: serializer.fromJson<bool>(json['isCurrent']),
      updatedAt: serializer.fromJson<DateTime>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'uuid': serializer.toJson<String>(uuid),
      'name': serializer.toJson<String>(name),
      'startDate': serializer.toJson<DateTime>(startDate),
      'totalWeeks': serializer.toJson<int>(totalWeeks),
      'isCurrent': serializer.toJson<bool>(isCurrent),
      'updatedAt': serializer.toJson<DateTime>(updatedAt),
    };
  }

  Semester copyWith(
          {int? id,
          String? uuid,
          String? name,
          DateTime? startDate,
          int? totalWeeks,
          bool? isCurrent,
          DateTime? updatedAt}) =>
      Semester(
        id: id ?? this.id,
        uuid: uuid ?? this.uuid,
        name: name ?? this.name,
        startDate: startDate ?? this.startDate,
        totalWeeks: totalWeeks ?? this.totalWeeks,
        isCurrent: isCurrent ?? this.isCurrent,
        updatedAt: updatedAt ?? this.updatedAt,
      );
  Semester copyWithCompanion(SemestersCompanion data) {
    return Semester(
      id: data.id.present ? data.id.value : this.id,
      uuid: data.uuid.present ? data.uuid.value : this.uuid,
      name: data.name.present ? data.name.value : this.name,
      startDate: data.startDate.present ? data.startDate.value : this.startDate,
      totalWeeks:
          data.totalWeeks.present ? data.totalWeeks.value : this.totalWeeks,
      isCurrent: data.isCurrent.present ? data.isCurrent.value : this.isCurrent,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('Semester(')
          ..write('id: $id, ')
          ..write('uuid: $uuid, ')
          ..write('name: $name, ')
          ..write('startDate: $startDate, ')
          ..write('totalWeeks: $totalWeeks, ')
          ..write('isCurrent: $isCurrent, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(id, uuid, name, startDate, totalWeeks, isCurrent, updatedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Semester &&
          other.id == this.id &&
          other.uuid == this.uuid &&
          other.name == this.name &&
          other.startDate == this.startDate &&
          other.totalWeeks == this.totalWeeks &&
          other.isCurrent == this.isCurrent &&
          other.updatedAt == this.updatedAt);
}

class SemestersCompanion extends UpdateCompanion<Semester> {
  final Value<int> id;
  final Value<String> uuid;
  final Value<String> name;
  final Value<DateTime> startDate;
  final Value<int> totalWeeks;
  final Value<bool> isCurrent;
  final Value<DateTime> updatedAt;
  const SemestersCompanion({
    this.id = const Value.absent(),
    this.uuid = const Value.absent(),
    this.name = const Value.absent(),
    this.startDate = const Value.absent(),
    this.totalWeeks = const Value.absent(),
    this.isCurrent = const Value.absent(),
    this.updatedAt = const Value.absent(),
  });
  SemestersCompanion.insert({
    this.id = const Value.absent(),
    this.uuid = const Value.absent(),
    required String name,
    required DateTime startDate,
    this.totalWeeks = const Value.absent(),
    this.isCurrent = const Value.absent(),
    this.updatedAt = const Value.absent(),
  })  : name = Value(name),
        startDate = Value(startDate);
  static Insertable<Semester> custom({
    Expression<int>? id,
    Expression<String>? uuid,
    Expression<String>? name,
    Expression<DateTime>? startDate,
    Expression<int>? totalWeeks,
    Expression<bool>? isCurrent,
    Expression<DateTime>? updatedAt,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (uuid != null) 'uuid': uuid,
      if (name != null) 'name': name,
      if (startDate != null) 'start_date': startDate,
      if (totalWeeks != null) 'total_weeks': totalWeeks,
      if (isCurrent != null) 'is_current': isCurrent,
      if (updatedAt != null) 'updated_at': updatedAt,
    });
  }

  SemestersCompanion copyWith(
      {Value<int>? id,
      Value<String>? uuid,
      Value<String>? name,
      Value<DateTime>? startDate,
      Value<int>? totalWeeks,
      Value<bool>? isCurrent,
      Value<DateTime>? updatedAt}) {
    return SemestersCompanion(
      id: id ?? this.id,
      uuid: uuid ?? this.uuid,
      name: name ?? this.name,
      startDate: startDate ?? this.startDate,
      totalWeeks: totalWeeks ?? this.totalWeeks,
      isCurrent: isCurrent ?? this.isCurrent,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (uuid.present) {
      map['uuid'] = Variable<String>(uuid.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (startDate.present) {
      map['start_date'] = Variable<DateTime>(startDate.value);
    }
    if (totalWeeks.present) {
      map['total_weeks'] = Variable<int>(totalWeeks.value);
    }
    if (isCurrent.present) {
      map['is_current'] = Variable<bool>(isCurrent.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<DateTime>(updatedAt.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SemestersCompanion(')
          ..write('id: $id, ')
          ..write('uuid: $uuid, ')
          ..write('name: $name, ')
          ..write('startDate: $startDate, ')
          ..write('totalWeeks: $totalWeeks, ')
          ..write('isCurrent: $isCurrent, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }
}

class $CoursesTable extends Courses with TableInfo<$CoursesTable, Course> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $CoursesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
      'id', aliasedName, false,
      hasAutoIncrement: true,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('PRIMARY KEY AUTOINCREMENT'));
  static const VerificationMeta _uuidMeta = const VerificationMeta('uuid');
  @override
  late final GeneratedColumn<String> uuid = GeneratedColumn<String>(
      'uuid', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant(''));
  static const VerificationMeta _semesterIdMeta =
      const VerificationMeta('semesterId');
  @override
  late final GeneratedColumn<int> semesterId = GeneratedColumn<int>(
      'semester_id', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
      'name', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _teacherMeta =
      const VerificationMeta('teacher');
  @override
  late final GeneratedColumn<String> teacher = GeneratedColumn<String>(
      'teacher', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant(''));
  static const VerificationMeta _colorMeta = const VerificationMeta('color');
  @override
  late final GeneratedColumn<int> color = GeneratedColumn<int>(
      'color', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _noteMeta = const VerificationMeta('note');
  @override
  late final GeneratedColumn<String> note = GeneratedColumn<String>(
      'note', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant(''));
  static const VerificationMeta _updatedAtMeta =
      const VerificationMeta('updatedAt');
  @override
  late final GeneratedColumn<DateTime> updatedAt = GeneratedColumn<DateTime>(
      'updated_at', aliasedName, false,
      type: DriftSqlType.dateTime, requiredDuringInsert: true);
  @override
  List<GeneratedColumn> get $columns =>
      [id, uuid, semesterId, name, teacher, color, note, updatedAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'courses';
  @override
  VerificationContext validateIntegrity(Insertable<Course> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('uuid')) {
      context.handle(
          _uuidMeta, uuid.isAcceptableOrUnknown(data['uuid']!, _uuidMeta));
    }
    if (data.containsKey('semester_id')) {
      context.handle(
          _semesterIdMeta,
          semesterId.isAcceptableOrUnknown(
              data['semester_id']!, _semesterIdMeta));
    } else if (isInserting) {
      context.missing(_semesterIdMeta);
    }
    if (data.containsKey('name')) {
      context.handle(
          _nameMeta, name.isAcceptableOrUnknown(data['name']!, _nameMeta));
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('teacher')) {
      context.handle(_teacherMeta,
          teacher.isAcceptableOrUnknown(data['teacher']!, _teacherMeta));
    }
    if (data.containsKey('color')) {
      context.handle(
          _colorMeta, color.isAcceptableOrUnknown(data['color']!, _colorMeta));
    } else if (isInserting) {
      context.missing(_colorMeta);
    }
    if (data.containsKey('note')) {
      context.handle(
          _noteMeta, note.isAcceptableOrUnknown(data['note']!, _noteMeta));
    }
    if (data.containsKey('updated_at')) {
      context.handle(_updatedAtMeta,
          updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta));
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  Course map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return Course(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}id'])!,
      uuid: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}uuid'])!,
      semesterId: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}semester_id'])!,
      name: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}name'])!,
      teacher: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}teacher'])!,
      color: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}color'])!,
      note: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}note'])!,
      updatedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}updated_at'])!,
    );
  }

  @override
  $CoursesTable createAlias(String alias) {
    return $CoursesTable(attachedDatabase, alias);
  }
}

class Course extends DataClass implements Insertable<Course> {
  final int id;
  final String uuid;
  final int semesterId;
  final String name;
  final String teacher;
  final int color;
  final String note;
  final DateTime updatedAt;
  const Course(
      {required this.id,
      required this.uuid,
      required this.semesterId,
      required this.name,
      required this.teacher,
      required this.color,
      required this.note,
      required this.updatedAt});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['uuid'] = Variable<String>(uuid);
    map['semester_id'] = Variable<int>(semesterId);
    map['name'] = Variable<String>(name);
    map['teacher'] = Variable<String>(teacher);
    map['color'] = Variable<int>(color);
    map['note'] = Variable<String>(note);
    map['updated_at'] = Variable<DateTime>(updatedAt);
    return map;
  }

  CoursesCompanion toCompanion(bool nullToAbsent) {
    return CoursesCompanion(
      id: Value(id),
      uuid: Value(uuid),
      semesterId: Value(semesterId),
      name: Value(name),
      teacher: Value(teacher),
      color: Value(color),
      note: Value(note),
      updatedAt: Value(updatedAt),
    );
  }

  factory Course.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return Course(
      id: serializer.fromJson<int>(json['id']),
      uuid: serializer.fromJson<String>(json['uuid']),
      semesterId: serializer.fromJson<int>(json['semesterId']),
      name: serializer.fromJson<String>(json['name']),
      teacher: serializer.fromJson<String>(json['teacher']),
      color: serializer.fromJson<int>(json['color']),
      note: serializer.fromJson<String>(json['note']),
      updatedAt: serializer.fromJson<DateTime>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'uuid': serializer.toJson<String>(uuid),
      'semesterId': serializer.toJson<int>(semesterId),
      'name': serializer.toJson<String>(name),
      'teacher': serializer.toJson<String>(teacher),
      'color': serializer.toJson<int>(color),
      'note': serializer.toJson<String>(note),
      'updatedAt': serializer.toJson<DateTime>(updatedAt),
    };
  }

  Course copyWith(
          {int? id,
          String? uuid,
          int? semesterId,
          String? name,
          String? teacher,
          int? color,
          String? note,
          DateTime? updatedAt}) =>
      Course(
        id: id ?? this.id,
        uuid: uuid ?? this.uuid,
        semesterId: semesterId ?? this.semesterId,
        name: name ?? this.name,
        teacher: teacher ?? this.teacher,
        color: color ?? this.color,
        note: note ?? this.note,
        updatedAt: updatedAt ?? this.updatedAt,
      );
  Course copyWithCompanion(CoursesCompanion data) {
    return Course(
      id: data.id.present ? data.id.value : this.id,
      uuid: data.uuid.present ? data.uuid.value : this.uuid,
      semesterId:
          data.semesterId.present ? data.semesterId.value : this.semesterId,
      name: data.name.present ? data.name.value : this.name,
      teacher: data.teacher.present ? data.teacher.value : this.teacher,
      color: data.color.present ? data.color.value : this.color,
      note: data.note.present ? data.note.value : this.note,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('Course(')
          ..write('id: $id, ')
          ..write('uuid: $uuid, ')
          ..write('semesterId: $semesterId, ')
          ..write('name: $name, ')
          ..write('teacher: $teacher, ')
          ..write('color: $color, ')
          ..write('note: $note, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(id, uuid, semesterId, name, teacher, color, note, updatedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Course &&
          other.id == this.id &&
          other.uuid == this.uuid &&
          other.semesterId == this.semesterId &&
          other.name == this.name &&
          other.teacher == this.teacher &&
          other.color == this.color &&
          other.note == this.note &&
          other.updatedAt == this.updatedAt);
}

class CoursesCompanion extends UpdateCompanion<Course> {
  final Value<int> id;
  final Value<String> uuid;
  final Value<int> semesterId;
  final Value<String> name;
  final Value<String> teacher;
  final Value<int> color;
  final Value<String> note;
  final Value<DateTime> updatedAt;
  const CoursesCompanion({
    this.id = const Value.absent(),
    this.uuid = const Value.absent(),
    this.semesterId = const Value.absent(),
    this.name = const Value.absent(),
    this.teacher = const Value.absent(),
    this.color = const Value.absent(),
    this.note = const Value.absent(),
    this.updatedAt = const Value.absent(),
  });
  CoursesCompanion.insert({
    this.id = const Value.absent(),
    this.uuid = const Value.absent(),
    required int semesterId,
    required String name,
    this.teacher = const Value.absent(),
    required int color,
    this.note = const Value.absent(),
    required DateTime updatedAt,
  })  : semesterId = Value(semesterId),
        name = Value(name),
        color = Value(color),
        updatedAt = Value(updatedAt);
  static Insertable<Course> custom({
    Expression<int>? id,
    Expression<String>? uuid,
    Expression<int>? semesterId,
    Expression<String>? name,
    Expression<String>? teacher,
    Expression<int>? color,
    Expression<String>? note,
    Expression<DateTime>? updatedAt,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (uuid != null) 'uuid': uuid,
      if (semesterId != null) 'semester_id': semesterId,
      if (name != null) 'name': name,
      if (teacher != null) 'teacher': teacher,
      if (color != null) 'color': color,
      if (note != null) 'note': note,
      if (updatedAt != null) 'updated_at': updatedAt,
    });
  }

  CoursesCompanion copyWith(
      {Value<int>? id,
      Value<String>? uuid,
      Value<int>? semesterId,
      Value<String>? name,
      Value<String>? teacher,
      Value<int>? color,
      Value<String>? note,
      Value<DateTime>? updatedAt}) {
    return CoursesCompanion(
      id: id ?? this.id,
      uuid: uuid ?? this.uuid,
      semesterId: semesterId ?? this.semesterId,
      name: name ?? this.name,
      teacher: teacher ?? this.teacher,
      color: color ?? this.color,
      note: note ?? this.note,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (uuid.present) {
      map['uuid'] = Variable<String>(uuid.value);
    }
    if (semesterId.present) {
      map['semester_id'] = Variable<int>(semesterId.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (teacher.present) {
      map['teacher'] = Variable<String>(teacher.value);
    }
    if (color.present) {
      map['color'] = Variable<int>(color.value);
    }
    if (note.present) {
      map['note'] = Variable<String>(note.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<DateTime>(updatedAt.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('CoursesCompanion(')
          ..write('id: $id, ')
          ..write('uuid: $uuid, ')
          ..write('semesterId: $semesterId, ')
          ..write('name: $name, ')
          ..write('teacher: $teacher, ')
          ..write('color: $color, ')
          ..write('note: $note, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }
}

class $SchedulesTable extends Schedules
    with TableInfo<$SchedulesTable, Schedule> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SchedulesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
      'id', aliasedName, false,
      hasAutoIncrement: true,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('PRIMARY KEY AUTOINCREMENT'));
  static const VerificationMeta _uuidMeta = const VerificationMeta('uuid');
  @override
  late final GeneratedColumn<String> uuid = GeneratedColumn<String>(
      'uuid', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant(''));
  static const VerificationMeta _courseIdMeta =
      const VerificationMeta('courseId');
  @override
  late final GeneratedColumn<int> courseId = GeneratedColumn<int>(
      'course_id', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _dayOfWeekMeta =
      const VerificationMeta('dayOfWeek');
  @override
  late final GeneratedColumn<int> dayOfWeek = GeneratedColumn<int>(
      'day_of_week', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _startSectionMeta =
      const VerificationMeta('startSection');
  @override
  late final GeneratedColumn<int> startSection = GeneratedColumn<int>(
      'start_section', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _endSectionMeta =
      const VerificationMeta('endSection');
  @override
  late final GeneratedColumn<int> endSection = GeneratedColumn<int>(
      'end_section', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  @override
  late final GeneratedColumnWithTypeConverter<WeeksType, int> weeksType =
      GeneratedColumn<int>('weeks_type', aliasedName, false,
              type: DriftSqlType.int, requiredDuringInsert: true)
          .withConverter<WeeksType>($SchedulesTable.$converterweeksType);
  static const VerificationMeta _customWeeksMeta =
      const VerificationMeta('customWeeks');
  @override
  late final GeneratedColumn<String> customWeeks = GeneratedColumn<String>(
      'custom_weeks', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant('[]'));
  static const VerificationMeta _locationMeta =
      const VerificationMeta('location');
  @override
  late final GeneratedColumn<String> location = GeneratedColumn<String>(
      'location', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant(''));
  static const VerificationMeta _updatedAtMeta =
      const VerificationMeta('updatedAt');
  @override
  late final GeneratedColumn<DateTime> updatedAt = GeneratedColumn<DateTime>(
      'updated_at', aliasedName, false,
      type: DriftSqlType.dateTime, requiredDuringInsert: true);
  @override
  List<GeneratedColumn> get $columns => [
        id,
        uuid,
        courseId,
        dayOfWeek,
        startSection,
        endSection,
        weeksType,
        customWeeks,
        location,
        updatedAt
      ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'schedules';
  @override
  VerificationContext validateIntegrity(Insertable<Schedule> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('uuid')) {
      context.handle(
          _uuidMeta, uuid.isAcceptableOrUnknown(data['uuid']!, _uuidMeta));
    }
    if (data.containsKey('course_id')) {
      context.handle(_courseIdMeta,
          courseId.isAcceptableOrUnknown(data['course_id']!, _courseIdMeta));
    } else if (isInserting) {
      context.missing(_courseIdMeta);
    }
    if (data.containsKey('day_of_week')) {
      context.handle(
          _dayOfWeekMeta,
          dayOfWeek.isAcceptableOrUnknown(
              data['day_of_week']!, _dayOfWeekMeta));
    } else if (isInserting) {
      context.missing(_dayOfWeekMeta);
    }
    if (data.containsKey('start_section')) {
      context.handle(
          _startSectionMeta,
          startSection.isAcceptableOrUnknown(
              data['start_section']!, _startSectionMeta));
    } else if (isInserting) {
      context.missing(_startSectionMeta);
    }
    if (data.containsKey('end_section')) {
      context.handle(
          _endSectionMeta,
          endSection.isAcceptableOrUnknown(
              data['end_section']!, _endSectionMeta));
    } else if (isInserting) {
      context.missing(_endSectionMeta);
    }
    if (data.containsKey('custom_weeks')) {
      context.handle(
          _customWeeksMeta,
          customWeeks.isAcceptableOrUnknown(
              data['custom_weeks']!, _customWeeksMeta));
    }
    if (data.containsKey('location')) {
      context.handle(_locationMeta,
          location.isAcceptableOrUnknown(data['location']!, _locationMeta));
    }
    if (data.containsKey('updated_at')) {
      context.handle(_updatedAtMeta,
          updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta));
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  Schedule map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return Schedule(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}id'])!,
      uuid: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}uuid'])!,
      courseId: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}course_id'])!,
      dayOfWeek: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}day_of_week'])!,
      startSection: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}start_section'])!,
      endSection: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}end_section'])!,
      weeksType: $SchedulesTable.$converterweeksType.fromSql(attachedDatabase
          .typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}weeks_type'])!),
      customWeeks: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}custom_weeks'])!,
      location: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}location'])!,
      updatedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}updated_at'])!,
    );
  }

  @override
  $SchedulesTable createAlias(String alias) {
    return $SchedulesTable(attachedDatabase, alias);
  }

  static JsonTypeConverter2<WeeksType, int, int> $converterweeksType =
      const EnumIndexConverter<WeeksType>(WeeksType.values);
}

class Schedule extends DataClass implements Insertable<Schedule> {
  final int id;
  final String uuid;
  final int courseId;
  final int dayOfWeek;
  final int startSection;
  final int endSection;
  final WeeksType weeksType;
  final String customWeeks;
  final String location;
  final DateTime updatedAt;
  const Schedule(
      {required this.id,
      required this.uuid,
      required this.courseId,
      required this.dayOfWeek,
      required this.startSection,
      required this.endSection,
      required this.weeksType,
      required this.customWeeks,
      required this.location,
      required this.updatedAt});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['uuid'] = Variable<String>(uuid);
    map['course_id'] = Variable<int>(courseId);
    map['day_of_week'] = Variable<int>(dayOfWeek);
    map['start_section'] = Variable<int>(startSection);
    map['end_section'] = Variable<int>(endSection);
    {
      map['weeks_type'] =
          Variable<int>($SchedulesTable.$converterweeksType.toSql(weeksType));
    }
    map['custom_weeks'] = Variable<String>(customWeeks);
    map['location'] = Variable<String>(location);
    map['updated_at'] = Variable<DateTime>(updatedAt);
    return map;
  }

  SchedulesCompanion toCompanion(bool nullToAbsent) {
    return SchedulesCompanion(
      id: Value(id),
      uuid: Value(uuid),
      courseId: Value(courseId),
      dayOfWeek: Value(dayOfWeek),
      startSection: Value(startSection),
      endSection: Value(endSection),
      weeksType: Value(weeksType),
      customWeeks: Value(customWeeks),
      location: Value(location),
      updatedAt: Value(updatedAt),
    );
  }

  factory Schedule.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return Schedule(
      id: serializer.fromJson<int>(json['id']),
      uuid: serializer.fromJson<String>(json['uuid']),
      courseId: serializer.fromJson<int>(json['courseId']),
      dayOfWeek: serializer.fromJson<int>(json['dayOfWeek']),
      startSection: serializer.fromJson<int>(json['startSection']),
      endSection: serializer.fromJson<int>(json['endSection']),
      weeksType: $SchedulesTable.$converterweeksType
          .fromJson(serializer.fromJson<int>(json['weeksType'])),
      customWeeks: serializer.fromJson<String>(json['customWeeks']),
      location: serializer.fromJson<String>(json['location']),
      updatedAt: serializer.fromJson<DateTime>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'uuid': serializer.toJson<String>(uuid),
      'courseId': serializer.toJson<int>(courseId),
      'dayOfWeek': serializer.toJson<int>(dayOfWeek),
      'startSection': serializer.toJson<int>(startSection),
      'endSection': serializer.toJson<int>(endSection),
      'weeksType': serializer
          .toJson<int>($SchedulesTable.$converterweeksType.toJson(weeksType)),
      'customWeeks': serializer.toJson<String>(customWeeks),
      'location': serializer.toJson<String>(location),
      'updatedAt': serializer.toJson<DateTime>(updatedAt),
    };
  }

  Schedule copyWith(
          {int? id,
          String? uuid,
          int? courseId,
          int? dayOfWeek,
          int? startSection,
          int? endSection,
          WeeksType? weeksType,
          String? customWeeks,
          String? location,
          DateTime? updatedAt}) =>
      Schedule(
        id: id ?? this.id,
        uuid: uuid ?? this.uuid,
        courseId: courseId ?? this.courseId,
        dayOfWeek: dayOfWeek ?? this.dayOfWeek,
        startSection: startSection ?? this.startSection,
        endSection: endSection ?? this.endSection,
        weeksType: weeksType ?? this.weeksType,
        customWeeks: customWeeks ?? this.customWeeks,
        location: location ?? this.location,
        updatedAt: updatedAt ?? this.updatedAt,
      );
  Schedule copyWithCompanion(SchedulesCompanion data) {
    return Schedule(
      id: data.id.present ? data.id.value : this.id,
      uuid: data.uuid.present ? data.uuid.value : this.uuid,
      courseId: data.courseId.present ? data.courseId.value : this.courseId,
      dayOfWeek: data.dayOfWeek.present ? data.dayOfWeek.value : this.dayOfWeek,
      startSection: data.startSection.present
          ? data.startSection.value
          : this.startSection,
      endSection:
          data.endSection.present ? data.endSection.value : this.endSection,
      weeksType: data.weeksType.present ? data.weeksType.value : this.weeksType,
      customWeeks:
          data.customWeeks.present ? data.customWeeks.value : this.customWeeks,
      location: data.location.present ? data.location.value : this.location,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('Schedule(')
          ..write('id: $id, ')
          ..write('uuid: $uuid, ')
          ..write('courseId: $courseId, ')
          ..write('dayOfWeek: $dayOfWeek, ')
          ..write('startSection: $startSection, ')
          ..write('endSection: $endSection, ')
          ..write('weeksType: $weeksType, ')
          ..write('customWeeks: $customWeeks, ')
          ..write('location: $location, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, uuid, courseId, dayOfWeek, startSection,
      endSection, weeksType, customWeeks, location, updatedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Schedule &&
          other.id == this.id &&
          other.uuid == this.uuid &&
          other.courseId == this.courseId &&
          other.dayOfWeek == this.dayOfWeek &&
          other.startSection == this.startSection &&
          other.endSection == this.endSection &&
          other.weeksType == this.weeksType &&
          other.customWeeks == this.customWeeks &&
          other.location == this.location &&
          other.updatedAt == this.updatedAt);
}

class SchedulesCompanion extends UpdateCompanion<Schedule> {
  final Value<int> id;
  final Value<String> uuid;
  final Value<int> courseId;
  final Value<int> dayOfWeek;
  final Value<int> startSection;
  final Value<int> endSection;
  final Value<WeeksType> weeksType;
  final Value<String> customWeeks;
  final Value<String> location;
  final Value<DateTime> updatedAt;
  const SchedulesCompanion({
    this.id = const Value.absent(),
    this.uuid = const Value.absent(),
    this.courseId = const Value.absent(),
    this.dayOfWeek = const Value.absent(),
    this.startSection = const Value.absent(),
    this.endSection = const Value.absent(),
    this.weeksType = const Value.absent(),
    this.customWeeks = const Value.absent(),
    this.location = const Value.absent(),
    this.updatedAt = const Value.absent(),
  });
  SchedulesCompanion.insert({
    this.id = const Value.absent(),
    this.uuid = const Value.absent(),
    required int courseId,
    required int dayOfWeek,
    required int startSection,
    required int endSection,
    required WeeksType weeksType,
    this.customWeeks = const Value.absent(),
    this.location = const Value.absent(),
    required DateTime updatedAt,
  })  : courseId = Value(courseId),
        dayOfWeek = Value(dayOfWeek),
        startSection = Value(startSection),
        endSection = Value(endSection),
        weeksType = Value(weeksType),
        updatedAt = Value(updatedAt);
  static Insertable<Schedule> custom({
    Expression<int>? id,
    Expression<String>? uuid,
    Expression<int>? courseId,
    Expression<int>? dayOfWeek,
    Expression<int>? startSection,
    Expression<int>? endSection,
    Expression<int>? weeksType,
    Expression<String>? customWeeks,
    Expression<String>? location,
    Expression<DateTime>? updatedAt,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (uuid != null) 'uuid': uuid,
      if (courseId != null) 'course_id': courseId,
      if (dayOfWeek != null) 'day_of_week': dayOfWeek,
      if (startSection != null) 'start_section': startSection,
      if (endSection != null) 'end_section': endSection,
      if (weeksType != null) 'weeks_type': weeksType,
      if (customWeeks != null) 'custom_weeks': customWeeks,
      if (location != null) 'location': location,
      if (updatedAt != null) 'updated_at': updatedAt,
    });
  }

  SchedulesCompanion copyWith(
      {Value<int>? id,
      Value<String>? uuid,
      Value<int>? courseId,
      Value<int>? dayOfWeek,
      Value<int>? startSection,
      Value<int>? endSection,
      Value<WeeksType>? weeksType,
      Value<String>? customWeeks,
      Value<String>? location,
      Value<DateTime>? updatedAt}) {
    return SchedulesCompanion(
      id: id ?? this.id,
      uuid: uuid ?? this.uuid,
      courseId: courseId ?? this.courseId,
      dayOfWeek: dayOfWeek ?? this.dayOfWeek,
      startSection: startSection ?? this.startSection,
      endSection: endSection ?? this.endSection,
      weeksType: weeksType ?? this.weeksType,
      customWeeks: customWeeks ?? this.customWeeks,
      location: location ?? this.location,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (uuid.present) {
      map['uuid'] = Variable<String>(uuid.value);
    }
    if (courseId.present) {
      map['course_id'] = Variable<int>(courseId.value);
    }
    if (dayOfWeek.present) {
      map['day_of_week'] = Variable<int>(dayOfWeek.value);
    }
    if (startSection.present) {
      map['start_section'] = Variable<int>(startSection.value);
    }
    if (endSection.present) {
      map['end_section'] = Variable<int>(endSection.value);
    }
    if (weeksType.present) {
      map['weeks_type'] = Variable<int>(
          $SchedulesTable.$converterweeksType.toSql(weeksType.value));
    }
    if (customWeeks.present) {
      map['custom_weeks'] = Variable<String>(customWeeks.value);
    }
    if (location.present) {
      map['location'] = Variable<String>(location.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<DateTime>(updatedAt.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SchedulesCompanion(')
          ..write('id: $id, ')
          ..write('uuid: $uuid, ')
          ..write('courseId: $courseId, ')
          ..write('dayOfWeek: $dayOfWeek, ')
          ..write('startSection: $startSection, ')
          ..write('endSection: $endSection, ')
          ..write('weeksType: $weeksType, ')
          ..write('customWeeks: $customWeeks, ')
          ..write('location: $location, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }
}

class $SettingsEntriesTable extends SettingsEntries
    with TableInfo<$SettingsEntriesTable, SettingsEntry> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SettingsEntriesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _keyMeta = const VerificationMeta('key');
  @override
  late final GeneratedColumn<String> key = GeneratedColumn<String>(
      'key', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _valueMeta = const VerificationMeta('value');
  @override
  late final GeneratedColumn<String> value = GeneratedColumn<String>(
      'value', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  @override
  List<GeneratedColumn> get $columns => [key, value];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'settings_entries';
  @override
  VerificationContext validateIntegrity(Insertable<SettingsEntry> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('key')) {
      context.handle(
          _keyMeta, key.isAcceptableOrUnknown(data['key']!, _keyMeta));
    } else if (isInserting) {
      context.missing(_keyMeta);
    }
    if (data.containsKey('value')) {
      context.handle(
          _valueMeta, value.isAcceptableOrUnknown(data['value']!, _valueMeta));
    } else if (isInserting) {
      context.missing(_valueMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {key};
  @override
  SettingsEntry map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return SettingsEntry(
      key: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}key'])!,
      value: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}value'])!,
    );
  }

  @override
  $SettingsEntriesTable createAlias(String alias) {
    return $SettingsEntriesTable(attachedDatabase, alias);
  }
}

class SettingsEntry extends DataClass implements Insertable<SettingsEntry> {
  final String key;
  final String value;
  const SettingsEntry({required this.key, required this.value});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['key'] = Variable<String>(key);
    map['value'] = Variable<String>(value);
    return map;
  }

  SettingsEntriesCompanion toCompanion(bool nullToAbsent) {
    return SettingsEntriesCompanion(
      key: Value(key),
      value: Value(value),
    );
  }

  factory SettingsEntry.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return SettingsEntry(
      key: serializer.fromJson<String>(json['key']),
      value: serializer.fromJson<String>(json['value']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'key': serializer.toJson<String>(key),
      'value': serializer.toJson<String>(value),
    };
  }

  SettingsEntry copyWith({String? key, String? value}) => SettingsEntry(
        key: key ?? this.key,
        value: value ?? this.value,
      );
  SettingsEntry copyWithCompanion(SettingsEntriesCompanion data) {
    return SettingsEntry(
      key: data.key.present ? data.key.value : this.key,
      value: data.value.present ? data.value.value : this.value,
    );
  }

  @override
  String toString() {
    return (StringBuffer('SettingsEntry(')
          ..write('key: $key, ')
          ..write('value: $value')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(key, value);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SettingsEntry &&
          other.key == this.key &&
          other.value == this.value);
}

class SettingsEntriesCompanion extends UpdateCompanion<SettingsEntry> {
  final Value<String> key;
  final Value<String> value;
  final Value<int> rowid;
  const SettingsEntriesCompanion({
    this.key = const Value.absent(),
    this.value = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  SettingsEntriesCompanion.insert({
    required String key,
    required String value,
    this.rowid = const Value.absent(),
  })  : key = Value(key),
        value = Value(value);
  static Insertable<SettingsEntry> custom({
    Expression<String>? key,
    Expression<String>? value,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (key != null) 'key': key,
      if (value != null) 'value': value,
      if (rowid != null) 'rowid': rowid,
    });
  }

  SettingsEntriesCompanion copyWith(
      {Value<String>? key, Value<String>? value, Value<int>? rowid}) {
    return SettingsEntriesCompanion(
      key: key ?? this.key,
      value: value ?? this.value,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (key.present) {
      map['key'] = Variable<String>(key.value);
    }
    if (value.present) {
      map['value'] = Variable<String>(value.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SettingsEntriesCompanion(')
          ..write('key: $key, ')
          ..write('value: $value, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $SyncStatesTable extends SyncStates
    with TableInfo<$SyncStatesTable, SyncState> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SyncStatesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _entityMeta = const VerificationMeta('entity');
  @override
  late final GeneratedColumn<String> entity = GeneratedColumn<String>(
      'entity', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _lastSyncedAtMeta =
      const VerificationMeta('lastSyncedAt');
  @override
  late final GeneratedColumn<DateTime> lastSyncedAt = GeneratedColumn<DateTime>(
      'last_synced_at', aliasedName, true,
      type: DriftSqlType.dateTime, requiredDuringInsert: false);
  static const VerificationMeta _dirtyMeta = const VerificationMeta('dirty');
  @override
  late final GeneratedColumn<bool> dirty = GeneratedColumn<bool>(
      'dirty', aliasedName, false,
      type: DriftSqlType.bool,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('CHECK ("dirty" IN (0, 1))'),
      defaultValue: const Constant(false));
  @override
  List<GeneratedColumn> get $columns => [entity, lastSyncedAt, dirty];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'sync_states';
  @override
  VerificationContext validateIntegrity(Insertable<SyncState> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('entity')) {
      context.handle(_entityMeta,
          entity.isAcceptableOrUnknown(data['entity']!, _entityMeta));
    } else if (isInserting) {
      context.missing(_entityMeta);
    }
    if (data.containsKey('last_synced_at')) {
      context.handle(
          _lastSyncedAtMeta,
          lastSyncedAt.isAcceptableOrUnknown(
              data['last_synced_at']!, _lastSyncedAtMeta));
    }
    if (data.containsKey('dirty')) {
      context.handle(
          _dirtyMeta, dirty.isAcceptableOrUnknown(data['dirty']!, _dirtyMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {entity};
  @override
  SyncState map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return SyncState(
      entity: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}entity'])!,
      lastSyncedAt: attachedDatabase.typeMapping.read(
          DriftSqlType.dateTime, data['${effectivePrefix}last_synced_at']),
      dirty: attachedDatabase.typeMapping
          .read(DriftSqlType.bool, data['${effectivePrefix}dirty'])!,
    );
  }

  @override
  $SyncStatesTable createAlias(String alias) {
    return $SyncStatesTable(attachedDatabase, alias);
  }
}

class SyncState extends DataClass implements Insertable<SyncState> {
  final String entity;
  final DateTime? lastSyncedAt;
  final bool dirty;
  const SyncState(
      {required this.entity, this.lastSyncedAt, required this.dirty});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['entity'] = Variable<String>(entity);
    if (!nullToAbsent || lastSyncedAt != null) {
      map['last_synced_at'] = Variable<DateTime>(lastSyncedAt);
    }
    map['dirty'] = Variable<bool>(dirty);
    return map;
  }

  SyncStatesCompanion toCompanion(bool nullToAbsent) {
    return SyncStatesCompanion(
      entity: Value(entity),
      lastSyncedAt: lastSyncedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(lastSyncedAt),
      dirty: Value(dirty),
    );
  }

  factory SyncState.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return SyncState(
      entity: serializer.fromJson<String>(json['entity']),
      lastSyncedAt: serializer.fromJson<DateTime?>(json['lastSyncedAt']),
      dirty: serializer.fromJson<bool>(json['dirty']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'entity': serializer.toJson<String>(entity),
      'lastSyncedAt': serializer.toJson<DateTime?>(lastSyncedAt),
      'dirty': serializer.toJson<bool>(dirty),
    };
  }

  SyncState copyWith(
          {String? entity,
          Value<DateTime?> lastSyncedAt = const Value.absent(),
          bool? dirty}) =>
      SyncState(
        entity: entity ?? this.entity,
        lastSyncedAt:
            lastSyncedAt.present ? lastSyncedAt.value : this.lastSyncedAt,
        dirty: dirty ?? this.dirty,
      );
  SyncState copyWithCompanion(SyncStatesCompanion data) {
    return SyncState(
      entity: data.entity.present ? data.entity.value : this.entity,
      lastSyncedAt: data.lastSyncedAt.present
          ? data.lastSyncedAt.value
          : this.lastSyncedAt,
      dirty: data.dirty.present ? data.dirty.value : this.dirty,
    );
  }

  @override
  String toString() {
    return (StringBuffer('SyncState(')
          ..write('entity: $entity, ')
          ..write('lastSyncedAt: $lastSyncedAt, ')
          ..write('dirty: $dirty')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(entity, lastSyncedAt, dirty);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SyncState &&
          other.entity == this.entity &&
          other.lastSyncedAt == this.lastSyncedAt &&
          other.dirty == this.dirty);
}

class SyncStatesCompanion extends UpdateCompanion<SyncState> {
  final Value<String> entity;
  final Value<DateTime?> lastSyncedAt;
  final Value<bool> dirty;
  final Value<int> rowid;
  const SyncStatesCompanion({
    this.entity = const Value.absent(),
    this.lastSyncedAt = const Value.absent(),
    this.dirty = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  SyncStatesCompanion.insert({
    required String entity,
    this.lastSyncedAt = const Value.absent(),
    this.dirty = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : entity = Value(entity);
  static Insertable<SyncState> custom({
    Expression<String>? entity,
    Expression<DateTime>? lastSyncedAt,
    Expression<bool>? dirty,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (entity != null) 'entity': entity,
      if (lastSyncedAt != null) 'last_synced_at': lastSyncedAt,
      if (dirty != null) 'dirty': dirty,
      if (rowid != null) 'rowid': rowid,
    });
  }

  SyncStatesCompanion copyWith(
      {Value<String>? entity,
      Value<DateTime?>? lastSyncedAt,
      Value<bool>? dirty,
      Value<int>? rowid}) {
    return SyncStatesCompanion(
      entity: entity ?? this.entity,
      lastSyncedAt: lastSyncedAt ?? this.lastSyncedAt,
      dirty: dirty ?? this.dirty,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (entity.present) {
      map['entity'] = Variable<String>(entity.value);
    }
    if (lastSyncedAt.present) {
      map['last_synced_at'] = Variable<DateTime>(lastSyncedAt.value);
    }
    if (dirty.present) {
      map['dirty'] = Variable<bool>(dirty.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SyncStatesCompanion(')
          ..write('entity: $entity, ')
          ..write('lastSyncedAt: $lastSyncedAt, ')
          ..write('dirty: $dirty, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $PendingDeletionsTable extends PendingDeletions
    with TableInfo<$PendingDeletionsTable, PendingDeletion> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $PendingDeletionsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
      'id', aliasedName, false,
      hasAutoIncrement: true,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('PRIMARY KEY AUTOINCREMENT'));
  static const VerificationMeta _entityMeta = const VerificationMeta('entity');
  @override
  late final GeneratedColumn<String> entity = GeneratedColumn<String>(
      'entity', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _uuidMeta = const VerificationMeta('uuid');
  @override
  late final GeneratedColumn<String> uuid = GeneratedColumn<String>(
      'uuid', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _parentUuidMeta =
      const VerificationMeta('parentUuid');
  @override
  late final GeneratedColumn<String> parentUuid = GeneratedColumn<String>(
      'parent_uuid', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant(''));
  static const VerificationMeta _deletedAtMeta =
      const VerificationMeta('deletedAt');
  @override
  late final GeneratedColumn<DateTime> deletedAt = GeneratedColumn<DateTime>(
      'deleted_at', aliasedName, false,
      type: DriftSqlType.dateTime, requiredDuringInsert: true);
  @override
  List<GeneratedColumn> get $columns =>
      [id, entity, uuid, parentUuid, deletedAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'pending_deletions';
  @override
  VerificationContext validateIntegrity(Insertable<PendingDeletion> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('entity')) {
      context.handle(_entityMeta,
          entity.isAcceptableOrUnknown(data['entity']!, _entityMeta));
    } else if (isInserting) {
      context.missing(_entityMeta);
    }
    if (data.containsKey('uuid')) {
      context.handle(
          _uuidMeta, uuid.isAcceptableOrUnknown(data['uuid']!, _uuidMeta));
    } else if (isInserting) {
      context.missing(_uuidMeta);
    }
    if (data.containsKey('parent_uuid')) {
      context.handle(
          _parentUuidMeta,
          parentUuid.isAcceptableOrUnknown(
              data['parent_uuid']!, _parentUuidMeta));
    }
    if (data.containsKey('deleted_at')) {
      context.handle(_deletedAtMeta,
          deletedAt.isAcceptableOrUnknown(data['deleted_at']!, _deletedAtMeta));
    } else if (isInserting) {
      context.missing(_deletedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  PendingDeletion map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return PendingDeletion(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}id'])!,
      entity: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}entity'])!,
      uuid: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}uuid'])!,
      parentUuid: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}parent_uuid'])!,
      deletedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}deleted_at'])!,
    );
  }

  @override
  $PendingDeletionsTable createAlias(String alias) {
    return $PendingDeletionsTable(attachedDatabase, alias);
  }
}

class PendingDeletion extends DataClass implements Insertable<PendingDeletion> {
  final int id;
  final String entity;
  final String uuid;
  final String parentUuid;
  final DateTime deletedAt;
  const PendingDeletion(
      {required this.id,
      required this.entity,
      required this.uuid,
      required this.parentUuid,
      required this.deletedAt});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['entity'] = Variable<String>(entity);
    map['uuid'] = Variable<String>(uuid);
    map['parent_uuid'] = Variable<String>(parentUuid);
    map['deleted_at'] = Variable<DateTime>(deletedAt);
    return map;
  }

  PendingDeletionsCompanion toCompanion(bool nullToAbsent) {
    return PendingDeletionsCompanion(
      id: Value(id),
      entity: Value(entity),
      uuid: Value(uuid),
      parentUuid: Value(parentUuid),
      deletedAt: Value(deletedAt),
    );
  }

  factory PendingDeletion.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return PendingDeletion(
      id: serializer.fromJson<int>(json['id']),
      entity: serializer.fromJson<String>(json['entity']),
      uuid: serializer.fromJson<String>(json['uuid']),
      parentUuid: serializer.fromJson<String>(json['parentUuid']),
      deletedAt: serializer.fromJson<DateTime>(json['deletedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'entity': serializer.toJson<String>(entity),
      'uuid': serializer.toJson<String>(uuid),
      'parentUuid': serializer.toJson<String>(parentUuid),
      'deletedAt': serializer.toJson<DateTime>(deletedAt),
    };
  }

  PendingDeletion copyWith(
          {int? id,
          String? entity,
          String? uuid,
          String? parentUuid,
          DateTime? deletedAt}) =>
      PendingDeletion(
        id: id ?? this.id,
        entity: entity ?? this.entity,
        uuid: uuid ?? this.uuid,
        parentUuid: parentUuid ?? this.parentUuid,
        deletedAt: deletedAt ?? this.deletedAt,
      );
  PendingDeletion copyWithCompanion(PendingDeletionsCompanion data) {
    return PendingDeletion(
      id: data.id.present ? data.id.value : this.id,
      entity: data.entity.present ? data.entity.value : this.entity,
      uuid: data.uuid.present ? data.uuid.value : this.uuid,
      parentUuid:
          data.parentUuid.present ? data.parentUuid.value : this.parentUuid,
      deletedAt: data.deletedAt.present ? data.deletedAt.value : this.deletedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('PendingDeletion(')
          ..write('id: $id, ')
          ..write('entity: $entity, ')
          ..write('uuid: $uuid, ')
          ..write('parentUuid: $parentUuid, ')
          ..write('deletedAt: $deletedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, entity, uuid, parentUuid, deletedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is PendingDeletion &&
          other.id == this.id &&
          other.entity == this.entity &&
          other.uuid == this.uuid &&
          other.parentUuid == this.parentUuid &&
          other.deletedAt == this.deletedAt);
}

class PendingDeletionsCompanion extends UpdateCompanion<PendingDeletion> {
  final Value<int> id;
  final Value<String> entity;
  final Value<String> uuid;
  final Value<String> parentUuid;
  final Value<DateTime> deletedAt;
  const PendingDeletionsCompanion({
    this.id = const Value.absent(),
    this.entity = const Value.absent(),
    this.uuid = const Value.absent(),
    this.parentUuid = const Value.absent(),
    this.deletedAt = const Value.absent(),
  });
  PendingDeletionsCompanion.insert({
    this.id = const Value.absent(),
    required String entity,
    required String uuid,
    this.parentUuid = const Value.absent(),
    required DateTime deletedAt,
  })  : entity = Value(entity),
        uuid = Value(uuid),
        deletedAt = Value(deletedAt);
  static Insertable<PendingDeletion> custom({
    Expression<int>? id,
    Expression<String>? entity,
    Expression<String>? uuid,
    Expression<String>? parentUuid,
    Expression<DateTime>? deletedAt,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (entity != null) 'entity': entity,
      if (uuid != null) 'uuid': uuid,
      if (parentUuid != null) 'parent_uuid': parentUuid,
      if (deletedAt != null) 'deleted_at': deletedAt,
    });
  }

  PendingDeletionsCompanion copyWith(
      {Value<int>? id,
      Value<String>? entity,
      Value<String>? uuid,
      Value<String>? parentUuid,
      Value<DateTime>? deletedAt}) {
    return PendingDeletionsCompanion(
      id: id ?? this.id,
      entity: entity ?? this.entity,
      uuid: uuid ?? this.uuid,
      parentUuid: parentUuid ?? this.parentUuid,
      deletedAt: deletedAt ?? this.deletedAt,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (entity.present) {
      map['entity'] = Variable<String>(entity.value);
    }
    if (uuid.present) {
      map['uuid'] = Variable<String>(uuid.value);
    }
    if (parentUuid.present) {
      map['parent_uuid'] = Variable<String>(parentUuid.value);
    }
    if (deletedAt.present) {
      map['deleted_at'] = Variable<DateTime>(deletedAt.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('PendingDeletionsCompanion(')
          ..write('id: $id, ')
          ..write('entity: $entity, ')
          ..write('uuid: $uuid, ')
          ..write('parentUuid: $parentUuid, ')
          ..write('deletedAt: $deletedAt')
          ..write(')'))
        .toString();
  }
}

abstract class _$AppDatabase extends GeneratedDatabase {
  _$AppDatabase(QueryExecutor e) : super(e);
  $AppDatabaseManager get managers => $AppDatabaseManager(this);
  late final $SemestersTable semesters = $SemestersTable(this);
  late final $CoursesTable courses = $CoursesTable(this);
  late final $SchedulesTable schedules = $SchedulesTable(this);
  late final $SettingsEntriesTable settingsEntries =
      $SettingsEntriesTable(this);
  late final $SyncStatesTable syncStates = $SyncStatesTable(this);
  late final $PendingDeletionsTable pendingDeletions =
      $PendingDeletionsTable(this);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
        semesters,
        courses,
        schedules,
        settingsEntries,
        syncStates,
        pendingDeletions
      ];
}

typedef $$SemestersTableCreateCompanionBuilder = SemestersCompanion Function({
  Value<int> id,
  Value<String> uuid,
  required String name,
  required DateTime startDate,
  Value<int> totalWeeks,
  Value<bool> isCurrent,
  Value<DateTime> updatedAt,
});
typedef $$SemestersTableUpdateCompanionBuilder = SemestersCompanion Function({
  Value<int> id,
  Value<String> uuid,
  Value<String> name,
  Value<DateTime> startDate,
  Value<int> totalWeeks,
  Value<bool> isCurrent,
  Value<DateTime> updatedAt,
});

class $$SemestersTableFilterComposer
    extends Composer<_$AppDatabase, $SemestersTable> {
  $$SemestersTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get uuid => $composableBuilder(
      column: $table.uuid, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get name => $composableBuilder(
      column: $table.name, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get startDate => $composableBuilder(
      column: $table.startDate, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get totalWeeks => $composableBuilder(
      column: $table.totalWeeks, builder: (column) => ColumnFilters(column));

  ColumnFilters<bool> get isCurrent => $composableBuilder(
      column: $table.isCurrent, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get updatedAt => $composableBuilder(
      column: $table.updatedAt, builder: (column) => ColumnFilters(column));
}

class $$SemestersTableOrderingComposer
    extends Composer<_$AppDatabase, $SemestersTable> {
  $$SemestersTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get uuid => $composableBuilder(
      column: $table.uuid, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get name => $composableBuilder(
      column: $table.name, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get startDate => $composableBuilder(
      column: $table.startDate, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get totalWeeks => $composableBuilder(
      column: $table.totalWeeks, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<bool> get isCurrent => $composableBuilder(
      column: $table.isCurrent, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get updatedAt => $composableBuilder(
      column: $table.updatedAt, builder: (column) => ColumnOrderings(column));
}

class $$SemestersTableAnnotationComposer
    extends Composer<_$AppDatabase, $SemestersTable> {
  $$SemestersTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get uuid =>
      $composableBuilder(column: $table.uuid, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<DateTime> get startDate =>
      $composableBuilder(column: $table.startDate, builder: (column) => column);

  GeneratedColumn<int> get totalWeeks => $composableBuilder(
      column: $table.totalWeeks, builder: (column) => column);

  GeneratedColumn<bool> get isCurrent =>
      $composableBuilder(column: $table.isCurrent, builder: (column) => column);

  GeneratedColumn<DateTime> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);
}

class $$SemestersTableTableManager extends RootTableManager<
    _$AppDatabase,
    $SemestersTable,
    Semester,
    $$SemestersTableFilterComposer,
    $$SemestersTableOrderingComposer,
    $$SemestersTableAnnotationComposer,
    $$SemestersTableCreateCompanionBuilder,
    $$SemestersTableUpdateCompanionBuilder,
    (Semester, BaseReferences<_$AppDatabase, $SemestersTable, Semester>),
    Semester,
    PrefetchHooks Function()> {
  $$SemestersTableTableManager(_$AppDatabase db, $SemestersTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SemestersTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SemestersTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SemestersTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<String> uuid = const Value.absent(),
            Value<String> name = const Value.absent(),
            Value<DateTime> startDate = const Value.absent(),
            Value<int> totalWeeks = const Value.absent(),
            Value<bool> isCurrent = const Value.absent(),
            Value<DateTime> updatedAt = const Value.absent(),
          }) =>
              SemestersCompanion(
            id: id,
            uuid: uuid,
            name: name,
            startDate: startDate,
            totalWeeks: totalWeeks,
            isCurrent: isCurrent,
            updatedAt: updatedAt,
          ),
          createCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<String> uuid = const Value.absent(),
            required String name,
            required DateTime startDate,
            Value<int> totalWeeks = const Value.absent(),
            Value<bool> isCurrent = const Value.absent(),
            Value<DateTime> updatedAt = const Value.absent(),
          }) =>
              SemestersCompanion.insert(
            id: id,
            uuid: uuid,
            name: name,
            startDate: startDate,
            totalWeeks: totalWeeks,
            isCurrent: isCurrent,
            updatedAt: updatedAt,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$SemestersTableProcessedTableManager = ProcessedTableManager<
    _$AppDatabase,
    $SemestersTable,
    Semester,
    $$SemestersTableFilterComposer,
    $$SemestersTableOrderingComposer,
    $$SemestersTableAnnotationComposer,
    $$SemestersTableCreateCompanionBuilder,
    $$SemestersTableUpdateCompanionBuilder,
    (Semester, BaseReferences<_$AppDatabase, $SemestersTable, Semester>),
    Semester,
    PrefetchHooks Function()>;
typedef $$CoursesTableCreateCompanionBuilder = CoursesCompanion Function({
  Value<int> id,
  Value<String> uuid,
  required int semesterId,
  required String name,
  Value<String> teacher,
  required int color,
  Value<String> note,
  required DateTime updatedAt,
});
typedef $$CoursesTableUpdateCompanionBuilder = CoursesCompanion Function({
  Value<int> id,
  Value<String> uuid,
  Value<int> semesterId,
  Value<String> name,
  Value<String> teacher,
  Value<int> color,
  Value<String> note,
  Value<DateTime> updatedAt,
});

class $$CoursesTableFilterComposer
    extends Composer<_$AppDatabase, $CoursesTable> {
  $$CoursesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get uuid => $composableBuilder(
      column: $table.uuid, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get semesterId => $composableBuilder(
      column: $table.semesterId, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get name => $composableBuilder(
      column: $table.name, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get teacher => $composableBuilder(
      column: $table.teacher, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get color => $composableBuilder(
      column: $table.color, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get note => $composableBuilder(
      column: $table.note, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get updatedAt => $composableBuilder(
      column: $table.updatedAt, builder: (column) => ColumnFilters(column));
}

class $$CoursesTableOrderingComposer
    extends Composer<_$AppDatabase, $CoursesTable> {
  $$CoursesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get uuid => $composableBuilder(
      column: $table.uuid, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get semesterId => $composableBuilder(
      column: $table.semesterId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get name => $composableBuilder(
      column: $table.name, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get teacher => $composableBuilder(
      column: $table.teacher, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get color => $composableBuilder(
      column: $table.color, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get note => $composableBuilder(
      column: $table.note, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get updatedAt => $composableBuilder(
      column: $table.updatedAt, builder: (column) => ColumnOrderings(column));
}

class $$CoursesTableAnnotationComposer
    extends Composer<_$AppDatabase, $CoursesTable> {
  $$CoursesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get uuid =>
      $composableBuilder(column: $table.uuid, builder: (column) => column);

  GeneratedColumn<int> get semesterId => $composableBuilder(
      column: $table.semesterId, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<String> get teacher =>
      $composableBuilder(column: $table.teacher, builder: (column) => column);

  GeneratedColumn<int> get color =>
      $composableBuilder(column: $table.color, builder: (column) => column);

  GeneratedColumn<String> get note =>
      $composableBuilder(column: $table.note, builder: (column) => column);

  GeneratedColumn<DateTime> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);
}

class $$CoursesTableTableManager extends RootTableManager<
    _$AppDatabase,
    $CoursesTable,
    Course,
    $$CoursesTableFilterComposer,
    $$CoursesTableOrderingComposer,
    $$CoursesTableAnnotationComposer,
    $$CoursesTableCreateCompanionBuilder,
    $$CoursesTableUpdateCompanionBuilder,
    (Course, BaseReferences<_$AppDatabase, $CoursesTable, Course>),
    Course,
    PrefetchHooks Function()> {
  $$CoursesTableTableManager(_$AppDatabase db, $CoursesTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$CoursesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$CoursesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$CoursesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<String> uuid = const Value.absent(),
            Value<int> semesterId = const Value.absent(),
            Value<String> name = const Value.absent(),
            Value<String> teacher = const Value.absent(),
            Value<int> color = const Value.absent(),
            Value<String> note = const Value.absent(),
            Value<DateTime> updatedAt = const Value.absent(),
          }) =>
              CoursesCompanion(
            id: id,
            uuid: uuid,
            semesterId: semesterId,
            name: name,
            teacher: teacher,
            color: color,
            note: note,
            updatedAt: updatedAt,
          ),
          createCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<String> uuid = const Value.absent(),
            required int semesterId,
            required String name,
            Value<String> teacher = const Value.absent(),
            required int color,
            Value<String> note = const Value.absent(),
            required DateTime updatedAt,
          }) =>
              CoursesCompanion.insert(
            id: id,
            uuid: uuid,
            semesterId: semesterId,
            name: name,
            teacher: teacher,
            color: color,
            note: note,
            updatedAt: updatedAt,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$CoursesTableProcessedTableManager = ProcessedTableManager<
    _$AppDatabase,
    $CoursesTable,
    Course,
    $$CoursesTableFilterComposer,
    $$CoursesTableOrderingComposer,
    $$CoursesTableAnnotationComposer,
    $$CoursesTableCreateCompanionBuilder,
    $$CoursesTableUpdateCompanionBuilder,
    (Course, BaseReferences<_$AppDatabase, $CoursesTable, Course>),
    Course,
    PrefetchHooks Function()>;
typedef $$SchedulesTableCreateCompanionBuilder = SchedulesCompanion Function({
  Value<int> id,
  Value<String> uuid,
  required int courseId,
  required int dayOfWeek,
  required int startSection,
  required int endSection,
  required WeeksType weeksType,
  Value<String> customWeeks,
  Value<String> location,
  required DateTime updatedAt,
});
typedef $$SchedulesTableUpdateCompanionBuilder = SchedulesCompanion Function({
  Value<int> id,
  Value<String> uuid,
  Value<int> courseId,
  Value<int> dayOfWeek,
  Value<int> startSection,
  Value<int> endSection,
  Value<WeeksType> weeksType,
  Value<String> customWeeks,
  Value<String> location,
  Value<DateTime> updatedAt,
});

class $$SchedulesTableFilterComposer
    extends Composer<_$AppDatabase, $SchedulesTable> {
  $$SchedulesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get uuid => $composableBuilder(
      column: $table.uuid, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get courseId => $composableBuilder(
      column: $table.courseId, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get dayOfWeek => $composableBuilder(
      column: $table.dayOfWeek, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get startSection => $composableBuilder(
      column: $table.startSection, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get endSection => $composableBuilder(
      column: $table.endSection, builder: (column) => ColumnFilters(column));

  ColumnWithTypeConverterFilters<WeeksType, WeeksType, int> get weeksType =>
      $composableBuilder(
          column: $table.weeksType,
          builder: (column) => ColumnWithTypeConverterFilters(column));

  ColumnFilters<String> get customWeeks => $composableBuilder(
      column: $table.customWeeks, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get location => $composableBuilder(
      column: $table.location, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get updatedAt => $composableBuilder(
      column: $table.updatedAt, builder: (column) => ColumnFilters(column));
}

class $$SchedulesTableOrderingComposer
    extends Composer<_$AppDatabase, $SchedulesTable> {
  $$SchedulesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get uuid => $composableBuilder(
      column: $table.uuid, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get courseId => $composableBuilder(
      column: $table.courseId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get dayOfWeek => $composableBuilder(
      column: $table.dayOfWeek, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get startSection => $composableBuilder(
      column: $table.startSection,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get endSection => $composableBuilder(
      column: $table.endSection, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get weeksType => $composableBuilder(
      column: $table.weeksType, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get customWeeks => $composableBuilder(
      column: $table.customWeeks, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get location => $composableBuilder(
      column: $table.location, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get updatedAt => $composableBuilder(
      column: $table.updatedAt, builder: (column) => ColumnOrderings(column));
}

class $$SchedulesTableAnnotationComposer
    extends Composer<_$AppDatabase, $SchedulesTable> {
  $$SchedulesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get uuid =>
      $composableBuilder(column: $table.uuid, builder: (column) => column);

  GeneratedColumn<int> get courseId =>
      $composableBuilder(column: $table.courseId, builder: (column) => column);

  GeneratedColumn<int> get dayOfWeek =>
      $composableBuilder(column: $table.dayOfWeek, builder: (column) => column);

  GeneratedColumn<int> get startSection => $composableBuilder(
      column: $table.startSection, builder: (column) => column);

  GeneratedColumn<int> get endSection => $composableBuilder(
      column: $table.endSection, builder: (column) => column);

  GeneratedColumnWithTypeConverter<WeeksType, int> get weeksType =>
      $composableBuilder(column: $table.weeksType, builder: (column) => column);

  GeneratedColumn<String> get customWeeks => $composableBuilder(
      column: $table.customWeeks, builder: (column) => column);

  GeneratedColumn<String> get location =>
      $composableBuilder(column: $table.location, builder: (column) => column);

  GeneratedColumn<DateTime> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);
}

class $$SchedulesTableTableManager extends RootTableManager<
    _$AppDatabase,
    $SchedulesTable,
    Schedule,
    $$SchedulesTableFilterComposer,
    $$SchedulesTableOrderingComposer,
    $$SchedulesTableAnnotationComposer,
    $$SchedulesTableCreateCompanionBuilder,
    $$SchedulesTableUpdateCompanionBuilder,
    (Schedule, BaseReferences<_$AppDatabase, $SchedulesTable, Schedule>),
    Schedule,
    PrefetchHooks Function()> {
  $$SchedulesTableTableManager(_$AppDatabase db, $SchedulesTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SchedulesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SchedulesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SchedulesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<String> uuid = const Value.absent(),
            Value<int> courseId = const Value.absent(),
            Value<int> dayOfWeek = const Value.absent(),
            Value<int> startSection = const Value.absent(),
            Value<int> endSection = const Value.absent(),
            Value<WeeksType> weeksType = const Value.absent(),
            Value<String> customWeeks = const Value.absent(),
            Value<String> location = const Value.absent(),
            Value<DateTime> updatedAt = const Value.absent(),
          }) =>
              SchedulesCompanion(
            id: id,
            uuid: uuid,
            courseId: courseId,
            dayOfWeek: dayOfWeek,
            startSection: startSection,
            endSection: endSection,
            weeksType: weeksType,
            customWeeks: customWeeks,
            location: location,
            updatedAt: updatedAt,
          ),
          createCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<String> uuid = const Value.absent(),
            required int courseId,
            required int dayOfWeek,
            required int startSection,
            required int endSection,
            required WeeksType weeksType,
            Value<String> customWeeks = const Value.absent(),
            Value<String> location = const Value.absent(),
            required DateTime updatedAt,
          }) =>
              SchedulesCompanion.insert(
            id: id,
            uuid: uuid,
            courseId: courseId,
            dayOfWeek: dayOfWeek,
            startSection: startSection,
            endSection: endSection,
            weeksType: weeksType,
            customWeeks: customWeeks,
            location: location,
            updatedAt: updatedAt,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$SchedulesTableProcessedTableManager = ProcessedTableManager<
    _$AppDatabase,
    $SchedulesTable,
    Schedule,
    $$SchedulesTableFilterComposer,
    $$SchedulesTableOrderingComposer,
    $$SchedulesTableAnnotationComposer,
    $$SchedulesTableCreateCompanionBuilder,
    $$SchedulesTableUpdateCompanionBuilder,
    (Schedule, BaseReferences<_$AppDatabase, $SchedulesTable, Schedule>),
    Schedule,
    PrefetchHooks Function()>;
typedef $$SettingsEntriesTableCreateCompanionBuilder = SettingsEntriesCompanion
    Function({
  required String key,
  required String value,
  Value<int> rowid,
});
typedef $$SettingsEntriesTableUpdateCompanionBuilder = SettingsEntriesCompanion
    Function({
  Value<String> key,
  Value<String> value,
  Value<int> rowid,
});

class $$SettingsEntriesTableFilterComposer
    extends Composer<_$AppDatabase, $SettingsEntriesTable> {
  $$SettingsEntriesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get key => $composableBuilder(
      column: $table.key, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get value => $composableBuilder(
      column: $table.value, builder: (column) => ColumnFilters(column));
}

class $$SettingsEntriesTableOrderingComposer
    extends Composer<_$AppDatabase, $SettingsEntriesTable> {
  $$SettingsEntriesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get key => $composableBuilder(
      column: $table.key, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get value => $composableBuilder(
      column: $table.value, builder: (column) => ColumnOrderings(column));
}

class $$SettingsEntriesTableAnnotationComposer
    extends Composer<_$AppDatabase, $SettingsEntriesTable> {
  $$SettingsEntriesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get key =>
      $composableBuilder(column: $table.key, builder: (column) => column);

  GeneratedColumn<String> get value =>
      $composableBuilder(column: $table.value, builder: (column) => column);
}

class $$SettingsEntriesTableTableManager extends RootTableManager<
    _$AppDatabase,
    $SettingsEntriesTable,
    SettingsEntry,
    $$SettingsEntriesTableFilterComposer,
    $$SettingsEntriesTableOrderingComposer,
    $$SettingsEntriesTableAnnotationComposer,
    $$SettingsEntriesTableCreateCompanionBuilder,
    $$SettingsEntriesTableUpdateCompanionBuilder,
    (
      SettingsEntry,
      BaseReferences<_$AppDatabase, $SettingsEntriesTable, SettingsEntry>
    ),
    SettingsEntry,
    PrefetchHooks Function()> {
  $$SettingsEntriesTableTableManager(
      _$AppDatabase db, $SettingsEntriesTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SettingsEntriesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SettingsEntriesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SettingsEntriesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> key = const Value.absent(),
            Value<String> value = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              SettingsEntriesCompanion(
            key: key,
            value: value,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String key,
            required String value,
            Value<int> rowid = const Value.absent(),
          }) =>
              SettingsEntriesCompanion.insert(
            key: key,
            value: value,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$SettingsEntriesTableProcessedTableManager = ProcessedTableManager<
    _$AppDatabase,
    $SettingsEntriesTable,
    SettingsEntry,
    $$SettingsEntriesTableFilterComposer,
    $$SettingsEntriesTableOrderingComposer,
    $$SettingsEntriesTableAnnotationComposer,
    $$SettingsEntriesTableCreateCompanionBuilder,
    $$SettingsEntriesTableUpdateCompanionBuilder,
    (
      SettingsEntry,
      BaseReferences<_$AppDatabase, $SettingsEntriesTable, SettingsEntry>
    ),
    SettingsEntry,
    PrefetchHooks Function()>;
typedef $$SyncStatesTableCreateCompanionBuilder = SyncStatesCompanion Function({
  required String entity,
  Value<DateTime?> lastSyncedAt,
  Value<bool> dirty,
  Value<int> rowid,
});
typedef $$SyncStatesTableUpdateCompanionBuilder = SyncStatesCompanion Function({
  Value<String> entity,
  Value<DateTime?> lastSyncedAt,
  Value<bool> dirty,
  Value<int> rowid,
});

class $$SyncStatesTableFilterComposer
    extends Composer<_$AppDatabase, $SyncStatesTable> {
  $$SyncStatesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get entity => $composableBuilder(
      column: $table.entity, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get lastSyncedAt => $composableBuilder(
      column: $table.lastSyncedAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<bool> get dirty => $composableBuilder(
      column: $table.dirty, builder: (column) => ColumnFilters(column));
}

class $$SyncStatesTableOrderingComposer
    extends Composer<_$AppDatabase, $SyncStatesTable> {
  $$SyncStatesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get entity => $composableBuilder(
      column: $table.entity, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get lastSyncedAt => $composableBuilder(
      column: $table.lastSyncedAt,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<bool> get dirty => $composableBuilder(
      column: $table.dirty, builder: (column) => ColumnOrderings(column));
}

class $$SyncStatesTableAnnotationComposer
    extends Composer<_$AppDatabase, $SyncStatesTable> {
  $$SyncStatesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get entity =>
      $composableBuilder(column: $table.entity, builder: (column) => column);

  GeneratedColumn<DateTime> get lastSyncedAt => $composableBuilder(
      column: $table.lastSyncedAt, builder: (column) => column);

  GeneratedColumn<bool> get dirty =>
      $composableBuilder(column: $table.dirty, builder: (column) => column);
}

class $$SyncStatesTableTableManager extends RootTableManager<
    _$AppDatabase,
    $SyncStatesTable,
    SyncState,
    $$SyncStatesTableFilterComposer,
    $$SyncStatesTableOrderingComposer,
    $$SyncStatesTableAnnotationComposer,
    $$SyncStatesTableCreateCompanionBuilder,
    $$SyncStatesTableUpdateCompanionBuilder,
    (SyncState, BaseReferences<_$AppDatabase, $SyncStatesTable, SyncState>),
    SyncState,
    PrefetchHooks Function()> {
  $$SyncStatesTableTableManager(_$AppDatabase db, $SyncStatesTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SyncStatesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SyncStatesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SyncStatesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> entity = const Value.absent(),
            Value<DateTime?> lastSyncedAt = const Value.absent(),
            Value<bool> dirty = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              SyncStatesCompanion(
            entity: entity,
            lastSyncedAt: lastSyncedAt,
            dirty: dirty,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String entity,
            Value<DateTime?> lastSyncedAt = const Value.absent(),
            Value<bool> dirty = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              SyncStatesCompanion.insert(
            entity: entity,
            lastSyncedAt: lastSyncedAt,
            dirty: dirty,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$SyncStatesTableProcessedTableManager = ProcessedTableManager<
    _$AppDatabase,
    $SyncStatesTable,
    SyncState,
    $$SyncStatesTableFilterComposer,
    $$SyncStatesTableOrderingComposer,
    $$SyncStatesTableAnnotationComposer,
    $$SyncStatesTableCreateCompanionBuilder,
    $$SyncStatesTableUpdateCompanionBuilder,
    (SyncState, BaseReferences<_$AppDatabase, $SyncStatesTable, SyncState>),
    SyncState,
    PrefetchHooks Function()>;
typedef $$PendingDeletionsTableCreateCompanionBuilder
    = PendingDeletionsCompanion Function({
  Value<int> id,
  required String entity,
  required String uuid,
  Value<String> parentUuid,
  required DateTime deletedAt,
});
typedef $$PendingDeletionsTableUpdateCompanionBuilder
    = PendingDeletionsCompanion Function({
  Value<int> id,
  Value<String> entity,
  Value<String> uuid,
  Value<String> parentUuid,
  Value<DateTime> deletedAt,
});

class $$PendingDeletionsTableFilterComposer
    extends Composer<_$AppDatabase, $PendingDeletionsTable> {
  $$PendingDeletionsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get entity => $composableBuilder(
      column: $table.entity, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get uuid => $composableBuilder(
      column: $table.uuid, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get parentUuid => $composableBuilder(
      column: $table.parentUuid, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get deletedAt => $composableBuilder(
      column: $table.deletedAt, builder: (column) => ColumnFilters(column));
}

class $$PendingDeletionsTableOrderingComposer
    extends Composer<_$AppDatabase, $PendingDeletionsTable> {
  $$PendingDeletionsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get entity => $composableBuilder(
      column: $table.entity, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get uuid => $composableBuilder(
      column: $table.uuid, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get parentUuid => $composableBuilder(
      column: $table.parentUuid, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get deletedAt => $composableBuilder(
      column: $table.deletedAt, builder: (column) => ColumnOrderings(column));
}

class $$PendingDeletionsTableAnnotationComposer
    extends Composer<_$AppDatabase, $PendingDeletionsTable> {
  $$PendingDeletionsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get entity =>
      $composableBuilder(column: $table.entity, builder: (column) => column);

  GeneratedColumn<String> get uuid =>
      $composableBuilder(column: $table.uuid, builder: (column) => column);

  GeneratedColumn<String> get parentUuid => $composableBuilder(
      column: $table.parentUuid, builder: (column) => column);

  GeneratedColumn<DateTime> get deletedAt =>
      $composableBuilder(column: $table.deletedAt, builder: (column) => column);
}

class $$PendingDeletionsTableTableManager extends RootTableManager<
    _$AppDatabase,
    $PendingDeletionsTable,
    PendingDeletion,
    $$PendingDeletionsTableFilterComposer,
    $$PendingDeletionsTableOrderingComposer,
    $$PendingDeletionsTableAnnotationComposer,
    $$PendingDeletionsTableCreateCompanionBuilder,
    $$PendingDeletionsTableUpdateCompanionBuilder,
    (
      PendingDeletion,
      BaseReferences<_$AppDatabase, $PendingDeletionsTable, PendingDeletion>
    ),
    PendingDeletion,
    PrefetchHooks Function()> {
  $$PendingDeletionsTableTableManager(
      _$AppDatabase db, $PendingDeletionsTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$PendingDeletionsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$PendingDeletionsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$PendingDeletionsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<String> entity = const Value.absent(),
            Value<String> uuid = const Value.absent(),
            Value<String> parentUuid = const Value.absent(),
            Value<DateTime> deletedAt = const Value.absent(),
          }) =>
              PendingDeletionsCompanion(
            id: id,
            entity: entity,
            uuid: uuid,
            parentUuid: parentUuid,
            deletedAt: deletedAt,
          ),
          createCompanionCallback: ({
            Value<int> id = const Value.absent(),
            required String entity,
            required String uuid,
            Value<String> parentUuid = const Value.absent(),
            required DateTime deletedAt,
          }) =>
              PendingDeletionsCompanion.insert(
            id: id,
            entity: entity,
            uuid: uuid,
            parentUuid: parentUuid,
            deletedAt: deletedAt,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$PendingDeletionsTableProcessedTableManager = ProcessedTableManager<
    _$AppDatabase,
    $PendingDeletionsTable,
    PendingDeletion,
    $$PendingDeletionsTableFilterComposer,
    $$PendingDeletionsTableOrderingComposer,
    $$PendingDeletionsTableAnnotationComposer,
    $$PendingDeletionsTableCreateCompanionBuilder,
    $$PendingDeletionsTableUpdateCompanionBuilder,
    (
      PendingDeletion,
      BaseReferences<_$AppDatabase, $PendingDeletionsTable, PendingDeletion>
    ),
    PendingDeletion,
    PrefetchHooks Function()>;

class $AppDatabaseManager {
  final _$AppDatabase _db;
  $AppDatabaseManager(this._db);
  $$SemestersTableTableManager get semesters =>
      $$SemestersTableTableManager(_db, _db.semesters);
  $$CoursesTableTableManager get courses =>
      $$CoursesTableTableManager(_db, _db.courses);
  $$SchedulesTableTableManager get schedules =>
      $$SchedulesTableTableManager(_db, _db.schedules);
  $$SettingsEntriesTableTableManager get settingsEntries =>
      $$SettingsEntriesTableTableManager(_db, _db.settingsEntries);
  $$SyncStatesTableTableManager get syncStates =>
      $$SyncStatesTableTableManager(_db, _db.syncStates);
  $$PendingDeletionsTableTableManager get pendingDeletions =>
      $$PendingDeletionsTableTableManager(_db, _db.pendingDeletions);
}
