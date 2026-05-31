// ignore_for_file: public_member_api_docs, sort_constructors_first
class AppArchiveModel {
  AppArchiveModel({
    required this.appName,
    required this.description,
    required this.items,
  });

  factory AppArchiveModel.fromJson(Map<String, dynamic> json) {
    return AppArchiveModel(
      appName: json["appName"] as String? ?? "",
      description: json["description"] as String? ?? "",
      items: List<ItemModel>.from(
        (json["items"] as List<dynamic>? ?? const []).map(
          (x) => ItemModel.fromJson(x as Map<String, dynamic>),
        ),
      ),
    );
  }
  final String appName;
  final String description;
  final List<ItemModel> items;

  Map<String, dynamic> toJson() {
    return {
      "appName": appName,
      "description": description,
      "items": List<dynamic>.from(items.map((x) => x.toJson())),
    };
  }
}

class ItemModel {
  ItemModel({
    required this.version,
    required this.shortVersion,
    required this.changes,
    required this.date,
    required this.mandatory,
    required this.url,
    required this.platform,
    this.changedFiles,
    this.removedFiles = const [],
    this.appName,
    this.manifestPath,
    this.channel,
  });

  factory ItemModel.fromJson(Map<String, dynamic> json) {
    return ItemModel(
      version: json["version"] as String? ?? "",
      shortVersion: json["shortVersion"] as int? ?? 0,
      changes: List<ChangeModel>.from(
        (json["changes"] as List<dynamic>? ?? const []).map(
          (x) => ChangeModel.fromJson(x as Map<String, dynamic>),
        ),
      ),
      date: json["date"] as String? ?? "",
      mandatory: json["mandatory"] as bool? ?? false,
      url: json["url"] as String? ?? "",
      platform: json["platform"] as String? ?? "",
      manifestPath: json["manifest"] as String?,
      channel: json["channel"] as String?,
    );
  }
  final String version;
  final int shortVersion;
  final List<ChangeModel> changes;
  final String date;
  final bool mandatory;
  final String url;
  final String platform;
  final List<FileHashModel?>? changedFiles;
  final List<String> removedFiles;
  final String? appName;
  final String? manifestPath;
  final String? channel;

  Map<String, dynamic> toJson() {
    return {
      "version": version,
      "shortVersion": shortVersion,
      "changes": List<dynamic>.from(changes.map((x) => x.toJson())),
      "date": date,
      "mandatory": mandatory,
      "url": url,
      "platform": platform,
      if (manifestPath != null) "manifest": manifestPath,
      if (channel != null) "channel": channel,
    };
  }

  ItemModel copyWith({
    String? version,
    int? shortVersion,
    List<ChangeModel>? changes,
    String? date,
    bool? mandatory,
    String? url,
    String? platform,
    List<FileHashModel?>? changedFiles,
    List<String>? removedFiles,
    String? appName,
    String? manifestPath,
    String? channel,
  }) {
    return ItemModel(
      version: version ?? this.version,
      shortVersion: shortVersion ?? this.shortVersion,
      changes: changes ?? this.changes,
      date: date ?? this.date,
      mandatory: mandatory ?? this.mandatory,
      url: url ?? this.url,
      platform: platform ?? this.platform,
      changedFiles: changedFiles ?? this.changedFiles,
      removedFiles: removedFiles ?? this.removedFiles,
      appName: appName ?? this.appName,
      manifestPath: manifestPath ?? this.manifestPath,
      channel: channel ?? this.channel,
    );
  }
}

class ChangeModel {
  ChangeModel({this.type, required this.message});

  factory ChangeModel.fromJson(Map<String, dynamic> json) {
    return ChangeModel(
      type: json["type"] as String?,
      message: json["message"] as String? ?? "",
    );
  }
  final String? type;
  final String message;

  Map<String, dynamic> toJson() {
    return {"type": type, "message": message};
  }
}

class FileHashModel {
  FileHashModel({
    required this.filePath,
    required this.calculatedHash,
    required this.length,
    this.kind = "file",
    this.sha256,
    this.mode,
    this.payloadPath,
    this.symlinkTarget,
  });

  factory FileHashModel.fromJson(Map<String, dynamic> json) {
    return FileHashModel(
      filePath: json["path"] as String? ?? "",
      calculatedHash: (json["calculatedHash"] as String?) ??
          (json["sha256"] as String?) ??
          "",
      length: json["length"] as int? ?? 0,
      kind: json["type"] as String? ?? "file",
      sha256: json["sha256"] as String?,
      mode: json["mode"] as String?,
      payloadPath: json["payload"] as String?,
      symlinkTarget: json["target"] as String?,
    );
  }
  final String filePath;
  final String calculatedHash;
  final int length;
  final String kind;
  final String? sha256;
  final String? mode;
  final String? payloadPath;
  final String? symlinkTarget;

  Map<String, dynamic> toJson() {
    return {
      "path": filePath,
      "calculatedHash": calculatedHash,
      "length": length,
      if (kind != "file") "type": kind,
      if (sha256 != null) "sha256": sha256,
      if (mode != null) "mode": mode,
      if (payloadPath != null) "payload": payloadPath,
      if (symlinkTarget != null) "target": symlinkTarget,
    };
  }
}
