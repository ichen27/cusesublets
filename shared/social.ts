export type SocialTarget = "listing" | "search";
export interface SocialComment {
  id: string;
  authorId: string | null;
  authorName: string;
  parentId: string | null;
  body: string;
  createdAt: string;
  editedAt: string | null;
  unavailable: boolean;
}
export interface SocialSummary {
  likeCount: number;
  commentCount: number;
  liked: boolean;
  saved: boolean;
  comments: SocialComment[];
  nextCursor: string | null;
}
export interface SavedPost {
  targetType: SocialTarget;
  targetId: string;
  available: boolean;
  savedAt: string;
}
export interface SavedPostsResponse {
  items: SavedPost[];
  nextCursor: string | null;
}
export interface SocialReport {
  id: string;
  commentId: string;
  reason: string;
  status: "open" | "resolved";
  createdAt: string;
  body: string;
  authorName: string;
  targetType: SocialTarget;
  targetId: string;
  removed: boolean;
  deleted: boolean;
}
