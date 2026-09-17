UPDATE users SET identity='pending' WHERE id='demo-host';
INSERT INTO listings(id,ownerId,status,leaseStatus,permissionStatus,data)
SELECT 'publish-pending','demo-host','pending','pending','pending',data FROM listings WHERE id='walnut-sunroom';
INSERT INTO listings(id,ownerId,status,data) SELECT 'publish-paused','demo-host','paused',data FROM listings WHERE id='walnut-sunroom';
INSERT INTO listings(id,ownerId,status,data) SELECT 'publish-rejected','demo-host','rejected',data FROM listings WHERE id='walnut-sunroom';
INSERT INTO listings(id,ownerId,status,data) SELECT 'publish-needs-info','demo-host','needs_info',data FROM listings WHERE id='walnut-sunroom';
INSERT INTO listings(id,ownerId,status,reviewNote,data) SELECT 'publish-held','demo-host','pending','Staff hold',data FROM listings WHERE id='walnut-sunroom';
