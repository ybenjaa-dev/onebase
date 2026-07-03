class Todo {
  const Todo({
    required this.id,
    required this.title,
    required this.done,
    required this.createdAt,
    required this.ownerId,
  });

  factory Todo.fromJson(Map<String, Object?> json) => Todo(
        id: json['id']! as String,
        title: (json['title'] as String?) ?? '',
        done: (json['done'] as bool?) ?? false,
        createdAt: (json['created_at'] as DateTime?) ?? DateTime(2000),
        ownerId: (json['owner_id'] as String?) ?? '',
      );

  final String id;
  final String title;
  final bool done;
  final DateTime createdAt;
  final String ownerId;

  Map<String, Object?> toJson() => {
        'id': id,
        'title': title,
        'done': done,
        'created_at': createdAt,
        'owner_id': ownerId,
      };
}
