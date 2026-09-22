// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'seerr_issue_models.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

SeerrIssueComment _$SeerrIssueCommentFromJson(Map<String, dynamic> json) =>
    SeerrIssueComment(
      id: (json['id'] as num?)?.toInt(),
      message: json['message'] as String?,
      user: json['user'] == null
          ? null
          : SeerrUserModel.fromJson(json['user'] as Map<String, dynamic>),
      createdAt: json['createdAt'] == null
          ? null
          : DateTime.parse(json['createdAt'] as String),
    );

Map<String, dynamic> _$SeerrIssueCommentToJson(SeerrIssueComment instance) =>
    <String, dynamic>{
      'id': instance.id,
      'message': instance.message,
      'user': instance.user,
      'createdAt': instance.createdAt?.toIso8601String(),
    };

SeerrIssue _$SeerrIssueFromJson(Map<String, dynamic> json) => SeerrIssue(
      id: (json['id'] as num).toInt(),
      issueType: (json['issueType'] as num).toInt(),
      status: (json['status'] as num).toInt(),
      media: json['media'] == null
          ? null
          : SeerrMedia.fromJson(json['media'] as Map<String, dynamic>),
      createdBy: json['createdBy'] == null
          ? null
          : SeerrUserModel.fromJson(json['createdBy'] as Map<String, dynamic>),
      createdAt: json['createdAt'] == null
          ? null
          : DateTime.parse(json['createdAt'] as String),
      updatedAt: json['updatedAt'] == null
          ? null
          : DateTime.parse(json['updatedAt'] as String),
      problemSeason: (json['problemSeason'] as num?)?.toInt(),
      problemEpisode: (json['problemEpisode'] as num?)?.toInt(),
      comments: (json['comments'] as List<dynamic>?)
              ?.map(
                  (e) => SeerrIssueComment.fromJson(e as Map<String, dynamic>))
              .toList() ??
          const [],
    );

Map<String, dynamic> _$SeerrIssueToJson(SeerrIssue instance) =>
    <String, dynamic>{
      'id': instance.id,
      'issueType': instance.issueType,
      'status': instance.status,
      'media': instance.media,
      'createdBy': instance.createdBy,
      'createdAt': instance.createdAt?.toIso8601String(),
      'updatedAt': instance.updatedAt?.toIso8601String(),
      'problemSeason': instance.problemSeason,
      'problemEpisode': instance.problemEpisode,
      'comments': instance.comments,
    };

SeerrIssuesResponse _$SeerrIssuesResponseFromJson(Map<String, dynamic> json) =>
    SeerrIssuesResponse(
      results: (json['results'] as List<dynamic>?)
              ?.map((e) => SeerrIssue.fromJson(e as Map<String, dynamic>))
              .toList() ??
          const [],
      pageInfo: json['pageInfo'] == null
          ? null
          : SeerrPageInfo.fromJson(json['pageInfo'] as Map<String, dynamic>),
    );

Map<String, dynamic> _$SeerrIssuesResponseToJson(
        SeerrIssuesResponse instance) =>
    <String, dynamic>{
      'results': instance.results,
      'pageInfo': instance.pageInfo,
    };
