%% =========================================================
% Settings
% ==========================================================

analysis_dir = 'D:/imagetransfer2026/Analysis_FSL/finished';

pairs = dir(fullfile(analysis_dir,'H*'));
pairs = pairs([pairs.isdir]);


%% ---------------------------------------------------------
% Windows path -> WSL path
%
% Example:
% D:\imagetransfer2026\xxx
% ->
% /mnt/d/imagetransfer2026/xxx
% ----------------------------------------------------------

win2wsl = @(p) regexprep( ...
    strrep(p,'\','/'), ...
    '^D:', ...
    '/mnt/d');


%% ---------------------------------------------------------
% FSL environment in WSL
% ----------------------------------------------------------

FSL_SETUP = '/home/sylsherry/fsl/etc/fslconf/fsl.sh';


%% ---------------------------------------------------------
% OLD standalone FIX
%
% Windows:
% D:\fix\fix
%
% WSL:
% /mnt/d/fix/fix
% ----------------------------------------------------------

FIX_PATH = '/mnt/d/fix/fix';


%% =========================================================
% Load masks
% ==========================================================

tempname = 'rTPM1.nii,1';

Y = spm_read_vols( ...
    spm_vol( ...
        fullfile(analysis_dir,'masks',tempname)));

Vmask = zeros([size(Y,1:3),5]);


for k = 2:6

    tempname = strcat( ...
        'rTPM', ...
        num2str(k), ...
        '.nii,1');

    V = spm_vol( ...
        fullfile( ...
            analysis_dir, ...
            'masks', ...
            tempname));

    Vmask(:,:,:,k-1) = ...
        spm_read_vols(V);

end


Vmask0 = squeeze(sum(Vmask,4));


CSFmask = spm_read_vols( ...
    spm_vol( ...
        fullfile( ...
            analysis_dir, ...
            'masks', ...
            'CSFmask.nii')));


%% =========================================================
% Frequency setting
% ==========================================================

fs = 0:1/3624/1:1;   % 604 * 6

[~,fsth01] = min(abs(fs-0.1));


%% =========================================================
% Start
% ==========================================================

h = waitbar(0,'estimation of the noise component');


for i = 1:length(pairs)

    waitbar(i/length(pairs),h);

    analysis_sub = pairs(i).name;

    fprintf('\n');
    fprintf('========================================\n');
    fprintf('subject -> %s\n',analysis_sub);
    fprintf('========================================\n');


    wrkdir = fullfile( ...
        pairs(i).folder, ...
        analysis_sub);


    %% =====================================================
    % Read MCFLIRT motion parameters
    %
    % Hxxxx/run1.feat/mc/prefiltered_func_data_mcf.par
    % ...
    % Hxxxx/run6.feat/mc/prefiltered_func_data_mcf.par
    % ======================================================

    fix_mc_dir = fullfile( ...
        wrkdir, ...
        'fix', ...
        'mc');


    if ~exist(fix_mc_dir,'dir')
        mkdir(fix_mc_dir);
    end


    nrun = 6;
    nvol = 604;

    f0 = zeros(nvol*nrun,6);


    for j = 1:nrun

        mcpar_file = fullfile( ...
            wrkdir, ...
            sprintf('run%d.feat',j), ...
            'mc', ...
            'prefiltered_func_data_mcf.par');


        if ~exist(mcpar_file,'file')

            error( ...
                'Motion parameter file not found: %s', ...
                mcpar_file);

        end


        % MCFLIRT .par is whitespace-delimited numeric text
        temp_motion = load(mcpar_file);


        if size(temp_motion,1) ~= nvol || ...
           size(temp_motion,2) ~= 6

            error( ...
                ['Unexpected dimensions in %s: ' ...
                 'found %d x %d, expected %d x 6'], ...
                mcpar_file, ...
                size(temp_motion,1), ...
                size(temp_motion,2), ...
                nvol);

        end


        f0( ...
            (j-1)*nvol+1:j*nvol, ...
            :) = temp_motion;

    end


    %% =====================================================
    % Save concatenated MCFLIRT parameters
    % ======================================================

    writematrix( ...
        f0, ...
        fullfile( ...
            fix_mc_dir, ...
            'prefiltered_func_data_mcf.par'), ...
        'Delimiter','space', ...
        'FileType','text');


    %% =====================================================
    % GICA directory
    % ======================================================

    temp = fullfile( ...
        pairs(i).folder, ...
        pairs(i).name, ...
        [pairs(i).name,'.gica']);


    if ~exist(temp,'dir')

        error( ...
            'GICA directory does not exist: %s', ...
            temp);

    end


    temp_wsl = win2wsl(temp);


    %% =====================================================
    % Create edge mask using OLD FIX
    %
    % Important:
    % The original pipeline expects FIX to eventually fail.
    % We only need edge1.nii.gz to have been created before
    % that failure.
    % ======================================================

    edge_nii = fullfile( ...
        temp, ...
        'fix', ...
        'edge1.nii');


    edge_gz = fullfile( ...
        temp, ...
        'fix', ...
        'edge1.nii.gz');


    % Do not check whether temp/fix exists.
    % Check whether edge1 itself exists.
    if ~exist(edge_nii,'file')


        %% -------------------------------------------------
        % If compressed edge mask is also absent, run OLD FIX
        % --------------------------------------------------

        if ~exist(edge_gz,'file')

            fprintf( ...
                'Running OLD FIX for %s...\n', ...
                analysis_sub);


            % Windows MATLAB -> WSL -> old FIX
            %
            % "bash FIX_PATH" is used so the script does not
            % depend on executable permission on the D: drive.
            %
            % FIX may later return an error. That is expected.
            cmd = sprintf( ...
                ['wsl bash -lc "' ...
                 'source ''%s''; ' ...
                 'bash ''%s'' -f ''%s''' ...
                 '"'], ...
                FSL_SETUP, ...
                FIX_PATH, ...
                temp_wsl);


            fprintf('Command:\n%s\n',cmd);


            % Intentionally do NOT error based on return status.
            % Old workflow expects FIX to fail later.
            system(cmd);

        end


        %% -------------------------------------------------
        % Did old FIX reach edge-mask generation?
        % --------------------------------------------------

        if ~exist(edge_gz,'file')

            error( ...
                ['OLD FIX did not create edge1.nii.gz for %s.\n' ...
                 'Expected file:\n%s'], ...
                analysis_sub, ...
                edge_gz);

        end


        %% -------------------------------------------------
        % Decompress edge1.nii.gz using WSL
        % --------------------------------------------------

        fprintf( ...
            'Decompressing edge1.nii.gz for %s...\n', ...
            analysis_sub);


        edge_gz_wsl = win2wsl(edge_gz);


        cmd = sprintf( ...
            'wsl gunzip -f "%s"', ...
            edge_gz_wsl);


        status = system(cmd);


        if status ~= 0

            error( ...
                'gunzip edge1.nii.gz failed for %s', ...
                analysis_sub);

        end

    end


    %% -----------------------------------------------------
    % Final edge mask check
    % ------------------------------------------------------

    if ~exist(edge_nii,'file')

        error( ...
            ['edge1.nii does not exist for %s.\n' ...
             'Expected:\n%s'], ...
            analysis_sub, ...
            edge_nii);

    end


    edgemask = spm_read_vols( ...
        spm_vol(edge_nii));


    %% =====================================================
    % Spatial specific analysis
    % ======================================================

    melodicnii = fullfile( ...
        temp, ...
        'melodic_IC');


    melodic_input_gz = ...
        [melodicnii '.nii.gz'];

    melodic_thr_gz = ...
        [melodicnii '5thr.nii.gz'];

    melodic_thr_nii = ...
        [melodicnii '5thr.nii'];


    %% -----------------------------------------------------
    % Threshold melodic IC maps using FSL
    % ------------------------------------------------------

    if ~exist(melodic_thr_nii,'file')


        % If compressed thresholded image doesn't exist,
        % create it using fslmaths
        if ~exist(melodic_thr_gz,'file')


            if ~exist(melodic_input_gz,'file')

                error( ...
                    'melodic_IC.nii.gz not found: %s', ...
                    melodic_input_gz);

            end


            fprintf( ...
                'Running fslmaths for %s...\n', ...
                analysis_sub);


            melodicnii_wsl = ...
                win2wsl(melodicnii);


            cmd = sprintf( ...
                ['wsl bash -lc "' ...
                 'source ''%s'' && ' ...
                 'fslmaths ''%s.nii.gz'' ' ...
                 '-thr 5 ' ...
                 '''%s5thr.nii.gz''' ...
                 '"'], ...
                FSL_SETUP, ...
                melodicnii_wsl, ...
                melodicnii_wsl);


            status = system(cmd);


            if status ~= 0

                error( ...
                    'fslmaths failed for %s', ...
                    analysis_sub);

            end

        end


        %% -------------------------------------------------
        % Decompress melodic_IC5thr.nii.gz
        % --------------------------------------------------

        fprintf( ...
            'Decompressing melodic_IC5thr.nii.gz for %s...\n', ...
            analysis_sub);


        melodic_thr_gz_wsl = ...
            win2wsl(melodic_thr_gz);


        cmd = sprintf( ...
            'wsl gunzip -f "%s"', ...
            melodic_thr_gz_wsl);


        status = system(cmd);


        if status ~= 0

            error( ...
                'gunzip melodic_IC5thr failed for %s', ...
                analysis_sub);

        end

    end


    %% -----------------------------------------------------
    % Read IC maps
    % ------------------------------------------------------

    ICmap = spm_read_vols( ...
        spm_vol(melodic_thr_nii));


    ICIC = zeros(size(ICmap,4),9);


    %% =====================================================
    % Spatial properties of each IC
    % ======================================================

    for j = 1:size(ICmap,4)

        temp1 = ICmap(:,:,:,j);


        %% -------------------------------------------------
        % CSF overlap
        % --------------------------------------------------

        temp2 = ...
            temp1 .* CSFmask;


        temp3 = ...
            sum(reshape(temp1,1,[]));


        temp4 = ...
            sum(reshape(temp2,1,[])) / temp3;


        ICIC(j,1) = temp4;


        %% -------------------------------------------------
        % Edge overlap
        % --------------------------------------------------

        temp2 = ...
            temp1 .* edgemask;


        temp4 = ...
            sum(reshape(temp2,1,[])) / temp3;


        ICIC(j,2) = temp4;


        %% -------------------------------------------------
        % Tissue masks
        % --------------------------------------------------

        for k = 1:4

            temp2 = ...
                temp1 .* Vmask(:,:,:,k);


            temp3 = ...
                sum(reshape(temp1,1,[]));


            temp4 = ...
                sum(reshape(temp2,1,[])) / temp3;


            ICIC(j,k+2) = temp4;

        end

    end


    %% =====================================================
    % Spatial criteria
    % ======================================================

    %{
    ICs1=or(ICIC(:,1)>0.2,ICIC(:,2)>0.8);
    ICs2=ICIC(:,3)>0.99;
    ICs3=ICIC(:,4)>0.6;
    ICs4=ICIC(:,5)+ICIC(:,6)>0.4;
    %}


    % Current criteria

    ICs1 = or( ...
        ICIC(:,1)>0.2, ...
        ICIC(:,2)>0.8);


    ICs2 = ...
        ICIC(:,3)>0.95;


    ICs3 = ...
        ICIC(:,4)>0.3;


    ICs4 = ...
        ICIC(:,5) + ICIC(:,6) > 0.4;


    %% =====================================================
    % Frequency specific analysis
    % ======================================================

    for j = 1:size(ICmap,4)

        freq_file = fullfile( ...
            temp, ...
            'report', ...
            strcat('f',num2str(j),'.txt'));


        fileID = fopen(freq_file);


        if fileID == -1

            error( ...
                'Cannot open frequency file: %s', ...
                freq_file);

        end


        f1 = textscan( ...
            fileID, ...
            '%s');


        fclose(fileID);


        f1 = cellfun( ...
            @str2double, ...
            f1{1}, ...
            'UniformOutput',false);


        f2 = table2array( ...
            cell2table(f1));


        freqlow = ...
            sum(f2(1:fsth01)) / sum(f2);


        ICIC(j,7) = freqlow;

    end


    ICs5 = ...
        ICIC(:,7)<0.3;


    %% =====================================================
    % Time series specific analysis
    % ======================================================

    concat_nii = fullfile( ...
        pairs(i).folder, ...
        pairs(i).name, ...
        'epi', ...
        'concat.nii');


    concat_gz = fullfile( ...
        pairs(i).folder, ...
        pairs(i).name, ...
        'epi', ...
        'concat.nii.gz');


    %% -----------------------------------------------------
    % Decompress concat.nii.gz if necessary
    % ------------------------------------------------------

    if ~exist(concat_nii,'file')


        if ~exist(concat_gz,'file')

            error( ...
                ['Neither concat.nii nor concat.nii.gz exists ' ...
                 'for %s.\nExpected:\n%s'], ...
                analysis_sub, ...
                concat_gz);

        end


        fprintf( ...
            'Decompressing concat.nii.gz for %s...\n', ...
            analysis_sub);


        concat_gz_wsl = ...
            win2wsl(concat_gz);


        cmd = sprintf( ...
            'wsl gunzip -f "%s"', ...
            concat_gz_wsl);


        status = system(cmd);


        if status ~= 0

            error( ...
                'gunzip concat.nii.gz failed for %s', ...
                analysis_sub);

        end

    end


    %% -----------------------------------------------------
    % Read concatenated functional data
    % ------------------------------------------------------

    concatsig = spm_read_vols( ...
        spm_vol(concat_nii));


    %% =====================================================
    % Extract CSF signal
    % ======================================================

    CSFsignal = bsxfun( ...
        @times, ...
        concatsig, ...
        CSFmask);


    CSFsignal = reshape( ...
        permute( ...
            CSFsignal, ...
            [4,1,2,3]), ...
        [], ...
        numel(CSFmask));


    index = find( ...
        reshape(CSFmask,[],1));


    CSFsignal = mean( ...
        CSFsignal(:,index), ...
        2);


    %% =====================================================
    % Time-series correlations
    % ======================================================

    for j = 1:size(ICmap,4)

        time_file = fullfile( ...
            temp, ...
            'report', ...
            strcat('t',num2str(j),'.txt'));


        fileID = fopen(time_file);


        if fileID == -1

            error( ...
                'Cannot open IC time-series file: %s', ...
                time_file);

        end


        f1 = textscan( ...
            fileID, ...
            '%s');


        fclose(fileID);


        f1 = cellfun( ...
            @str2double, ...
            f1{1}, ...
            'UniformOutput',false);


        f2 = table2array( ...
            cell2table(f1));


        %% -------------------------------------------------
        % Dimension checks
        % --------------------------------------------------

        if length(f2) ~= length(CSFsignal)

            error( ...
                ['IC time series and CSF signal lengths differ.\n' ...
                 'Subject: %s\n' ...
                 'IC: %d\n' ...
                 'CSF: %d'], ...
                analysis_sub, ...
                length(f2), ...
                length(CSFsignal));

        end


        if length(f2) ~= size(f0,1)

            error( ...
                ['IC time series and motion lengths differ.\n' ...
                 'Subject: %s\n' ...
                 'IC: %d\n' ...
                 'Motion: %d'], ...
                analysis_sub, ...
                length(f2), ...
                size(f0,1));

        end


        %% -------------------------------------------------
        % Spearman correlation
        % --------------------------------------------------

        temp2 = corr( ...
            [f2,CSFsignal,f0], ...
            'type','spearman');


        % Max absolute correlation with six motion parameters
        ICIC(j,8) = ...
            max(abs(temp2(1,3:end)));


        % Absolute correlation with CSF
        ICIC(j,9) = ...
            abs(temp2(1,2));

    end


    ICs6 = ...
        ICIC(:,8)>0.3;


    ICs7 = ...
        ICIC(:,9)>0.3;


    %% =====================================================
    % Combine all criteria
    % ======================================================

    ICs0 = sum( ...
        cat( ...
            2, ...
            ICs1, ...
            ICs2, ...
            ICs3, ...
            ICs4, ...
            ICs5, ...
            ICs6, ...
            ICs7), ...
        2);


    ICs = find(ICs0);


    fprintf( ...
        'Detected %d noise ICs for %s\n', ...
        length(ICs), ...
        analysis_sub);


    %% =====================================================
    % Write hand_labels_noise.txt
    % ======================================================

    noise_file = fullfile( ...
        temp, ...
        'hand_labels_noise.txt');


    fileID = fopen( ...
        noise_file, ...
        'w');


    if fileID == -1

        error( ...
            'Cannot create file: %s', ...
            noise_file);

    end


    fprintf(fileID,'[');


    if ~isempty(ICs)

        fprintf( ...
            fileID, ...
            '%d', ...
            ICs(1));


        for j = 2:length(ICs)

            fprintf( ...
                fileID, ...
                ',%d', ...
                ICs(j));

        end

    end


    fprintf(fileID,']');


    fclose(fileID);

end


close(h);