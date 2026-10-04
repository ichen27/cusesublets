INSERT INTO seeker_requests(id,ownerId,status,data,createdAt,updatedAt) VALUES
('old-paused','demo-renter','paused','{"title":"Old pause","description":"Historical search","neighborhood":"Westcott","maxBudget":800,"roomType":"Any","startDate":"2027-01-01","endDate":"2027-05-01","amenities":[]}','2026-09-01','2026-09-01'),
('chosen-active','demo-renter','active','{"title":"Active request","description":"Historical search","neighborhood":"Westcott","maxBudget":950,"roomType":"Private room","startDate":"2027-01-01","endDate":"2027-05-01","amenities":["Furnished"]}','2026-09-02','2026-09-02'),
('old-removed','demo-renter','removed','{"title":"Removed request","description":"Historical removed content","neighborhood":"Westcott","maxBudget":1000,"roomType":"Any","startDate":"2027-01-01","endDate":"2027-05-01","amenities":[]}','2026-09-03','2026-09-03'),
('removed-only','demo-admin','removed','{"title":"Removed only","description":"Historical removed content","neighborhood":"Westcott","maxBudget":1000,"roomType":"Any","startDate":"2027-01-01","endDate":"2027-05-01","amenities":[]}','2026-09-04','2026-09-04');
UPDATE conversations SET requestId='chosen-active' WHERE buyerId='demo-renter' AND listingId='walnut-sunroom';
INSERT INTO request_reports(id,requestId,reporterId,reason,createdAt)
VALUES('legacy-report','old-removed','demo-host','Historical report preserved','2026-09-05');
