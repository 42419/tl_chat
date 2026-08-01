// Pure routing state — which nodes are online and who belongs to which room.
// Kept free of sockets so it stays trivially testable.

export interface Room {
  id: string;
  name: string;
  owner: string;
  members: Set<string>;
}

export class ChatRouter {
  private readonly online = new Set<string>();
  private readonly rooms = new Map<string, Room>();

  isOnline(nodeId: string): boolean {
    return this.online.has(nodeId);
  }

  onlineNodes(): string[] {
    return [...this.online];
  }

  markOnline(nodeId: string): void {
    this.online.add(nodeId);
  }

  markOffline(nodeId: string): void {
    this.online.delete(nodeId);
  }

  createRoom(id: string, name: string, owner: string): Room {
    const room: Room = { id, name, owner, members: new Set([owner]) };
    this.rooms.set(id, room);
    return room;
  }

  joinRoom(id: string, nodeId: string): boolean {
    const room = this.rooms.get(id);
    if (!room) return false;
    room.members.add(nodeId);
    return true;
  }

  leaveRoom(id: string, nodeId: string): void {
    this.rooms.get(id)?.members.delete(nodeId);
  }

  roomMembers(id: string): string[] {
    return [...(this.rooms.get(id)?.members ?? [])];
  }

  roomById(id: string): Room | undefined {
    return this.rooms.get(id);
  }

  /** Room ids the node is a member of (for history queries). */
  roomsOf(nodeId: string): string[] {
    const ids: string[] = [];
    for (const [id, room] of this.rooms) {
      if (room.members.has(nodeId)) ids.push(id);
    }
    return ids;
  }

  /** All rooms (for browsing / joining existing groups). */
  allRooms(): Room[] {
    return [...this.rooms.values()];
  }
}
