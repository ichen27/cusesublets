export type ReviewStatus = "pending" | "verified" | "needs_info" | "rejected";
export interface User {
  id: string;
  name: string;
  email: string;
  role: "member" | "admin";
  identity: ReviewStatus;
  avatar?: string;
  suspended?: boolean;
}
export interface Listing {
  id: string;
  ownerId: string;
  title: string;
  neighborhood: string;
  address: string;
  lat: number;
  lng: number;
  price: number;
  beds: number;
  baths: number;
  roomType: "Private room" | "Entire place";
  startDate: string;
  endDate: string;
  description: string;
  amenities: string[];
  images: string[];
  videoUrl?: string;
  matterportUrl?: string;
  status: "pending" | "approved" | "needs_info" | "rejected" | "paused";
  leaseStatus: ReviewStatus;
  permissionStatus: ReviewStatus;
  hostName: string;
  hostIdentity: ReviewStatus;
  walkMinutes: number;
  sample: boolean;
  reviewNote?: string;
}
export interface Message {
  conversationId?: string;
  id: string;
  listingId: string;
  senderId: string;
  recipientId: string;
  body: string;
  createdAt: string;
}
export interface Offer {
  conversationId: string;
  proposedBy: string;
  parentOfferId?: string | null;
  createdAt: string;
  kind: "offer" | "request";
  id: string;
  listingId: string;
  buyerId: string;
  sellerId: string;
  amount: number;
  startDate: string;
  endDate: string;
  status: string;
  buyerName?: string;
  listingTitle?: string;
}
export interface Booking {
  id: string;
  listingId: string;
  buyerId: string;
  sellerId: string;
  amount: number;
  startDate: string;
  endDate: string;
  status: string;
  buyerSigned: boolean;
  sellerSigned: boolean;
  paymentStatus: string;
  moveInAt?: string;
  disputeStatus: string;
  listingTitle?: string;
}
export interface DocumentRecord {
  id: string;
  listingId: string;
  name: string;
  kind: string;
  createdAt: string;
}
export interface Audit {
  id: string;
  actorId: string;
  action: string;
  targetId: string;
  reason: string;
  createdAt: string;
}

export interface Report {
  id: string;
  listingId: string;
  reporterId: string;
  reason: string;
  status: "open" | "resolved";
  createdAt: string;
}

export interface Conversation {
  id: string;
  listingId: string;
  buyerId: string;
  sellerId: string;
  createdAt: string;
  updatedAt: string;
}
export interface ConversationSummary extends Conversation {
  listingTitle: string;
  listingImage: string;
  peerName: string;
  lastMessage?: string;
}
export interface ChatAttachment {
  id: string;
  conversationId: string;
  senderId: string;
  name: string;
  type: string;
  size: number;
  createdAt: string;
}
export interface ChatEvent {
  id: string;
  conversationId: string;
  actorId: string;
  kind: string;
  body: string;
  offerId?: string | null;
  createdAt: string;
}
export interface ConversationDetail {
  conversation: ConversationSummary;
  listing: Listing;
  peer: { id: string; name: string };
  messages: Message[];
  offers: Offer[];
  bookings: Booking[];
  attachments: ChatAttachment[];
  events: ChatEvent[];
}
