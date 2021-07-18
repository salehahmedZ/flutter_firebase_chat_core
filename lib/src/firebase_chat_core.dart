import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_chat_types/flutter_chat_types.dart' as types;

import 'util.dart';

/// Provides access to Firebase chat data. Singleton, use
/// FirebaseChatCore.instance to aceess methods.
class FirebaseChatCore {
  FirebaseChatCore._privateConstructor();

  /// Singleton instance
  static final FirebaseChatCore instance = FirebaseChatCore._privateConstructor();

  /// Creates a chat group room with [users]. Creator is automatically
  /// added to the group. [name] is required and will be used as
  /// a group name. Add an optional [imageUrl] that will be a group avatar
  /// and [metadata] for any additional custom data.
  Future<types.Room> createGroupRoom({
    required String authId,
    String? imageUrl,
    Map<String, dynamic>? metadata,
    required String name,
    required List<types.User> users,
  }) async {
    final currentUser = await fetchUser(authId);
    final roomUsers = [currentUser] + users;

    final room = await FirebaseFirestore.instance.collection('rooms').add({
      'createdAt': FieldValue.serverTimestamp(),
      'imageUrl': imageUrl,
      'metadata': metadata,
      'name': name,
      'type': types.RoomType.group.toShortString(),
      'updatedAt': FieldValue.serverTimestamp(),
      'userIds': roomUsers.map((u) => u.id).toList(),
      'userRoles': roomUsers.fold<Map<String, String?>>(
        {},
        (previousValue, element) => {
          ...previousValue,
          element.id: element.role?.toShortString(),
        },
      ),
    });

    return types.Room(
      id: room.id,
      imageUrl: imageUrl,
      metadata: metadata,
      name: name,
      type: types.RoomType.group,
      users: roomUsers,
    );
  }

  /// Creates a direct chat for 2 people. Add [metadata] for any additional
  /// custom data.
  Future<types.Room> createRoom(
    String authId,
    types.User otherUser, {
    Map<String, dynamic>? metadata,
  }) async {
    final query = await FirebaseFirestore.instance.collection('rooms').where('userIds', arrayContains: authId).get();

    final rooms = await processRoomsQuery(authId, query);

    try {
      return rooms.firstWhere((room) {
        if (room.type == types.RoomType.group) return false;

        final userIds = room.users.map((u) => u.id);
        return userIds.contains(authId) && userIds.contains(otherUser.id);
      });
    } catch (e) {
      // Do nothing if room does not exist
      // Create a new room instead
    }

    final currentUser = await fetchUser(authId);
    final users = [currentUser, otherUser];

    final roomId = int.parse(authId) + int.parse(otherUser.id);
    await FirebaseFirestore.instance.collection('rooms').doc(roomId.toString()).set({
      'createdAt': FieldValue.serverTimestamp(),
      'imageUrl': null,
      'metadata': metadata,
      'name': null,
      'type': types.RoomType.direct.toShortString(),
      'updatedAt': FieldValue.serverTimestamp(),
      'userIds': users.map((u) => u.id).toList(),
      'userRoles': null,
    });
    final roomCreated = FirebaseFirestore.instance.collection('rooms').doc(roomId.toString());
    return types.Room(
      id: roomCreated.id,
      metadata: metadata,
      type: types.RoomType.direct,
      users: users,
    );
  }

  /// Creates [types.User] in Firebase to store name and avatar used on
  /// rooms list
  Future<void> createUserInFirestore(types.User user) async {
    await FirebaseFirestore.instance.collection('users').doc(user.id).set({
      'createdAt': FieldValue.serverTimestamp(),
      'firstName': user.firstName,
      'imageUrl': user.imageUrl,
      'lastName': user.lastName,
      'lastSeen': user.lastSeen,
      'metadata': user.metadata,
      'role': user.role?.toShortString(),
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  /// Removes [types.User] from `users` collection in Firebase
  Future<void> deleteUserFromFirestore(String userId) async {
    await FirebaseFirestore.instance.collection('users').doc(userId).delete();
  }

  /// Returns a stream of messages from Firebase for a given room
  Stream<List<types.Message>> messages(types.Room room) {
    return FirebaseFirestore.instance.collection('rooms/${room.id}/messages').orderBy('createdAt', descending: true).snapshots().map(
      (snapshot) {
        return snapshot.docs.fold<List<types.Message>>(
          [],
          (previousValue, element) {
            final data = element.data();
            final author = room.users.firstWhere(
              (u) => u.id == data['authorId'],
              orElse: () => types.User(id: data['authorId'] as String),
            );

            data['author'] = author.toJson();
            data['id'] = element.id;
            try {
              data['createdAt'] = element['createdAt']?.millisecondsSinceEpoch;
              data['updatedAt'] = element['updatedAt']?.millisecondsSinceEpoch;
            } catch (e) {
              // Ignore errors, null values are ok
            }
            data.removeWhere((key, value) => key == 'authorId');
            return [...previousValue, types.Message.fromJson(data)];
          },
        );
      },
    );
  }

  /// Returns a stream of changes in a room from Firebase
  Stream<types.Room> room(String roomId, String authId) {
    return FirebaseFirestore.instance.collection('rooms').doc(roomId).snapshots().asyncMap((doc) => processRoomDocument(doc, authId));
  }

  /// Returns a stream of rooms from Firebase. Only rooms where current
  /// logged in user exist are returned. [orderByUpdatedAt] is used in case
  /// you want to have last modified rooms on top, there are a couple
  /// of things you will need to do though:
  /// 1) Make sure `updatedAt` exists on all rooms
  /// 2) Write a Cloud Function which will update `updatedAt` of the room
  /// when the room changes or new messages come in
  /// 3) Create an Index (Firestore Database -> Indexes tab) where collection ID
  /// is `rooms`, field indexed are `userIds` (type Arrays) and `updatedAt`
  /// (type Descending), query scope is `Collection`
  Stream<List<types.Room>> rooms(String authId, {bool orderByUpdatedAt = false}) {
    final collection = orderByUpdatedAt
        ? FirebaseFirestore.instance.collection('rooms').where('userIds', arrayContains: authId).orderBy('updatedAt', descending: true)
        : FirebaseFirestore.instance.collection('rooms').where('userIds', arrayContains: authId);

    return collection.snapshots().asyncMap((query) => processRoomsQuery(authId, query));
  }

  /// Sends a message to the Firestore. Accepts any partial message and a
  /// room ID. If arbitraty data is provided in the [partialMessage]
  /// does nothing.
  void sendMessage(dynamic partialMessage, String roomId, String authId) async {
    types.Message? message;

    if (partialMessage is types.PartialFile) {
      message = types.FileMessage.fromPartial(
        author: types.User(id: authId),
        id: '',
        partialFile: partialMessage,
      );
    } else if (partialMessage is types.PartialImage) {
      message = types.ImageMessage.fromPartial(
        author: types.User(id: authId),
        id: '',
        partialImage: partialMessage,
      );
    } else if (partialMessage is types.PartialText) {
      message = types.TextMessage.fromPartial(
        author: types.User(id: authId),
        id: '',
        partialText: partialMessage,
      );
    }

    if (message != null) {
      final messageMap = message.toJson();
      messageMap.removeWhere((key, value) => key == 'author' || key == 'id');
      messageMap['authorId'] = authId;
      messageMap['createdAt'] = FieldValue.serverTimestamp();
      messageMap['updatedAt'] = FieldValue.serverTimestamp();

      await FirebaseFirestore.instance.collection('rooms/$roomId/messages').add(messageMap);
    }
  }

  /// Updates a message in the Firestore. Accepts any message and a
  /// room ID. Message will probably be taken from the [messages] stream.
  void updateMessage(types.Message message, String roomId, String authId) async {
    if (message.author.id != authId) return;

    final messageMap = message.toJson();
    messageMap.removeWhere((key, value) => key == 'id' || key == 'createdAt');
    messageMap['updatedAt'] = FieldValue.serverTimestamp();

    await FirebaseFirestore.instance.collection('rooms/$roomId/messages').doc(message.id).update(messageMap);
  }

  /// Returns a stream of all users from Firebase
  Stream<List<types.User>> users(String authId) {
    return FirebaseFirestore.instance.collection('users').snapshots().map(
          (snapshot) => snapshot.docs.fold<List<types.User>>(
            [],
            (previousValue, element) {
              if (authId == element.id) return previousValue;

              return [...previousValue, processUserDocument(element)];
            },
          ),
        );
  }
}
