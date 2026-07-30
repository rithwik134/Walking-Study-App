# WayWalk Analyser for Mac

## Open the application

1. Unzip `WayWalk_Analyser_Mac.zip`.
2. Move **WayWalk Analyser.app** to your Applications folder.
3. The first time you open it, right-click the app and choose **Open**.
4. If macOS asks for confirmation, choose **Open** again.

The app uses the Python 3 installation already on your Mac.

## First run

If the app says required packages are missing:

1. Click **Install required packages**.
2. Wait for the completion message.
3. Close and reopen the app.

## Run an analysis

1. Click **Choose…** beside **Empatica folder** and select the folder containing one walk's five CSV exports.
2. Select the matching `zones.csv`.
3. Select where the Excel file should be saved.
4. Click **Run analysis**.

The app calculates only the agreed outputs:

- Mean EDA
- Peak EDA
- Mean pulse
- Peak pulse
- Mean PRV
- Mean acceleration
- Wearing percentage
- Valid sample counts

The supplied `zones.csv` contains the P03B B-to-A timings already provided.
For another walk, edit a copy of `zones.csv` in Excel or Numbers, preserving the headings `Zone`, `In`, and `Out` and using `HH:MM:SS`.
