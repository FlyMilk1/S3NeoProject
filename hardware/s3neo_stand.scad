// Parametric 3D Printable Desk Stand for Samsung Galaxy S3 Neo (GT-I9301I)
// Dimensions: 136.6 x 70.7 x 8.6 mm (with clearance tolerances)
// Features: 62-degree viewing angle, front-redirected rear speaker horn, micro-USB cable channel

$fn = 64;

phone_w = 138.0; // Landscape width (136.6mm + tolerance)
phone_h = 72.0;  // Landscape height (70.7mm + tolerance)
phone_d = 10.2;  // Thickness (8.6mm + tolerance)
tilt_angle = 28; // 90 - 62 deg viewing angle

base_w = 150;
base_d = 95;
base_h = 14;

module s3neo_cutout() {
    translate([0, 0, 8])
    rotate([tilt_angle, 0, 0]) {
        // Main phone body slot
        translate([-phone_w/2, -phone_d/2, 0])
            cube([phone_w, phone_d, phone_h]);
        
        // Front screen viewport cutout
        translate([-(phone_w-10)/2, -phone_d - 5, 6])
            cube([phone_w-10, phone_d + 6, phone_h]);
            
        // Rear camera & speaker acoustic intake cavity
        translate([phone_w/2 - 36, 0, 12])
            cube([28, 18, 30]);
            
        // Right-side Micro-USB charging cable channel
        translate([phone_w/2 - 2, -4, 18])
            cube([20, 8, 16]);
    }
}

module acoustic_horn() {
    // Channels rear speaker audio from the back of the S3 Neo out the front base
    translate([phone_w/2 - 32, -base_d/2 + 2, 3])
        cube([24, base_d/2 + 15, 7]);
}

difference() {
    // Outer stand body
    hull() {
        translate([-base_w/2, -base_d/2, 0])
            cube([base_w, base_d, base_h]);
        translate([-base_w/2 + 4, -12, 0])
            cube([base_w - 8, 28, 38]);
    }
    
    // Subtract phone cradle, acoustic horn, and bottom mic clearance
    s3neo_cutout();
    acoustic_horn();
}
